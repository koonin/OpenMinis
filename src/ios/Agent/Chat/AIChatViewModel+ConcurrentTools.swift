//
//  AIChatViewModel+ConcurrentTools.swift
//  MinisApp
//
//  Concurrent tool execution: dispatches up to `maxConcurrentTools` tool
//  calls in parallel via TaskGroup, waits for all to complete, then
//  returns results ordered to match the original tool_use sequence
//  (Anthropic API requires tool_result order to mirror tool_use order
//  within the same user message).
//
//  Created for T-concurrent-tools 2026-05-25.
//

import Foundation
import UIKit

private let ctLogger = AppLogger(category: "AIChatVM")

/// Global cap across parent sessions. The normal tool dispatcher can run ten
/// tools concurrently, but worker sessions are heavier (each owns a full agent
/// loop and provider stream), so delegation has its own smaller gate.
private actor DelegatedWorkerConcurrencyGate {
    static let shared = DelegatedWorkerConcurrencyGate()
    private let limit = 3
    private var inFlight = 0

    /// Returns false when the caller's end-to-end deadline expires while
    /// queued. There is no stored waiter to leak: cancellation interrupts the
    /// short sleep and the task leaves the queue immediately.
    func acquire(until deadline: Date) async throws -> Bool {
        while inFlight >= limit {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            let sleepNanos = UInt64(min(remaining, 0.05) * 1_000_000_000)
            try await Task.sleep(nanoseconds: max(1, sleepNanos))
        }
        try Task.checkCancellation()
        guard Date() < deadline else { return false }
        inFlight += 1
        return true
    }

    func release() {
        inFlight = max(0, inFlight - 1)
    }
}

extension AIChatViewModel {

    /// Hard cap on simultaneous in-flight tool executions per agent turn.
    /// 10 is the requested ceiling; iSH itself can fan out further but
    /// concurrent shell forks on the emulator past this start to compete
    /// for emulator scheduling.
    static let maxConcurrentTools = 10

    /// Set-typed view of currently-running shell PIDs.
    ///
    /// Backed by the singular `runningCommandPid: Int32` slot on
    /// AIChatViewModel so `AIChatViewModel+ISHCommand`'s pidCallback
    /// (which assigns `runningCommandPid = pid`) keeps working
    /// unchanged. The stop button enumerates this Set to kill every
    /// in-flight shell across a concurrent batch. When per-task PID
    /// tracking lands this can be promoted to true Set storage with
    /// per-task insert/remove.
    ///
    /// [T-ios-concurrent-toolcall-dup-id]
    var runningCommandPids: Set<Int32> {
        get { runningCommandPid > 0 ? [runningCommandPid] : [] }
        set { runningCommandPid = newValue.first ?? 0 }
    }

    /// Tiny actor wrapping the per-turn image budget so concurrent tool
    /// tasks can race-free claim a slot for their image bytes.
    /// `reserveSlot()` returns true iff a slot was claimed; the caller
    /// then attaches `imageData` to its toolResult. False → caller must
    /// substitute a text placeholder.
    actor BatchImageBudget {
        private var remaining: Int
        private(set) var strippedCount: Int = 0

        init(initial: Int) { self.remaining = max(0, initial) }

        /// Claim one image slot. Returns true if granted.
        func reserveSlot() -> Bool {
            if remaining > 0 {
                remaining -= 1
                return true
            }
            strippedCount += 1
            return false
        }

        var strippedSoFar: Int { strippedCount }
    }

    /// Outcome of executing a single tool call. Collected by each child
    /// task and merged in original index order by the outer dispatcher.
    struct ToolExecOutcome {
        let toolId: String
        let toolName: String
        let resultPart: AgentContentPart            // .toolResult(...)
        let snapshotEntry: (toolName: String, snapshot: ToolSnapshot)?
        let snapshotItem: ToolSnapshotItem?
        let cancelled: Bool
    }

    struct DelegatedWorkerRunResult {
        let status: String
        let sessionId: String?
        let modelName: String?
        let workerGroupId: String?
        let workerGroupName: String?
        let output: String
        let error: String?

        var success: Bool { status == "success" }

        init(
            status: String,
            sessionId: String?,
            modelName: String?,
            workerGroupId: String? = nil,
            workerGroupName: String? = nil,
            output: String,
            error: String?
        ) {
            self.status = status
            self.sessionId = sessionId
            self.modelName = modelName
            self.workerGroupId = workerGroupId
            self.workerGroupName = workerGroupName
            self.output = output
            self.error = error
        }

        func jsonString() -> String {
            var object: [String: Any] = [
                "status": status,
                "session_id": sessionId ?? NSNull(),
                "worker_group_id": workerGroupId ?? NSNull(),
                "worker_group": workerGroupName ?? NSNull(),
                "model_name": modelName ?? NSNull(),
                "output": output,
                "error": error ?? NSNull(),
            ]
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8) else {
                return "{\"status\":\"error\",\"session_id\":null,\"worker_group_id\":null,\"worker_group\":null,\"model_name\":null,\"output\":\"\",\"error\":\"Could not encode worker result\"}"
            }
            return string
        }
    }

    /// Run one full, independently persisted worker session. The group and a
    /// concrete text model are resolved before creating the session, and the
    /// binding is then written explicitly so the worker can never fall through
    /// to Default Primary.
    func executeDelegatedWorker(arguments: [String: Any]) async throws -> DelegatedWorkerRunResult {
        guard !isDelegatedWorkerSession else {
            return DelegatedWorkerRunResult(
                status: "error", sessionId: nil, modelName: nil, output: "",
                error: "Delegated workers cannot delegate further."
            )
        }
        let taskText = (arguments["task"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !taskText.isEmpty else {
            return DelegatedWorkerRunResult(
                status: "error", sessionId: nil, modelName: nil, output: "",
                error: "Missing required task."
            )
        }

        let requestedTimeout = arguments["timeout_seconds"] as? Int ?? 180
        let timeoutSeconds = min(max(requestedTimeout, 10), 900)
        // The public timeout is wall-clock time for the whole delegation,
        // including the dedicated-worker gate and session setup.
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        let routeKey = UUID().uuidString
        guard let worker = resolvedWorkerConfiguration(for: routeKey) else {
            return DelegatedWorkerRunResult(
                status: "error", sessionId: nil, modelName: nil, output: "",
                error: "Worker Group is missing or has no enabled, credentialed text-output model. Configure it in Settings → Model Groups."
            )
        }

        do {
            guard try await DelegatedWorkerConcurrencyGate.shared.acquire(until: deadline) else {
                return DelegatedWorkerRunResult(
                    status: "timeout", sessionId: nil, modelName: nil,
                    workerGroupId: worker.group.id, workerGroupName: worker.group.name,
                    output: "", error: "Worker exceeded the \(timeoutSeconds)-second timeout while waiting to start."
                )
            }
        } catch is CancellationError {
            return DelegatedWorkerRunResult(
                status: "cancelled", sessionId: nil, modelName: nil,
                workerGroupId: worker.group.id, workerGroupName: worker.group.name,
                output: "", error: "Worker was cancelled before it started."
            )
        }
        do {
            let result = try await performDelegatedWorker(
                arguments: arguments,
                taskText: taskText,
                group: worker.group,
                entryId: worker.entryId,
                timeoutSeconds: timeoutSeconds,
                deadline: deadline
            )
            await DelegatedWorkerConcurrencyGate.shared.release()
            return result
        } catch is CancellationError {
            await DelegatedWorkerConcurrencyGate.shared.release()
            return DelegatedWorkerRunResult(
                status: "cancelled", sessionId: nil, modelName: nil,
                workerGroupId: worker.group.id, workerGroupName: worker.group.name,
                output: "", error: "Worker was cancelled."
            )
        } catch {
            await DelegatedWorkerConcurrencyGate.shared.release()
            throw error
        }
    }

    private func performDelegatedWorker(
        arguments: [String: Any],
        taskText: String,
        group: ModelGroup,
        entryId: String,
        timeoutSeconds: Int,
        deadline: Date
    ) async throws -> DelegatedWorkerRunResult {
        try Task.checkCancellation()
        guard Date() < deadline else {
            return DelegatedWorkerRunResult(
                status: "timeout", sessionId: nil, modelName: nil,
                workerGroupId: group.id, workerGroupName: group.name, output: "",
                error: "Worker exceeded the \(timeoutSeconds)-second timeout before session creation."
            )
        }
        let store = ProviderConfigStore.shared
        guard var entry = store.entry(for: entryId) else {
            return DelegatedWorkerRunResult(
                status: "error", sessionId: nil, modelName: nil,
                workerGroupId: group.id, workerGroupName: group.name, output: "",
                error: "The resolved worker model is no longer available."
            )
        }

        let title = ((arguments["tool_title"] as? String) ?? "Delegated task")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = (arguments["expected_output"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let workerVM = ViewModelCache.shared.createDraft()
        workerVM.sessionSource = Self.delegatedWorkerSessionSource
        workerVM.initialGroupId = group.id
        workerVM.selectedModel = entry.model

        let workerSessionId = await workerVM.ensureSessionReturningId(makeActive: false)

        if Task.isCancelled {
            workerVM.cancel()
            SessionConcurrencyManager.shared.cancelWait(sessionId: workerSessionId)
            return DelegatedWorkerRunResult(
                status: "cancelled", sessionId: workerSessionId,
                modelName: entry.model.displayName,
                workerGroupId: group.id, workerGroupName: group.name, output: "",
                error: "Worker was cancelled during session setup."
            )
        }
        guard Date() < deadline else {
            workerVM.cancel()
            SessionConcurrencyManager.shared.cancelWait(sessionId: workerSessionId)
            return DelegatedWorkerRunResult(
                status: "timeout", sessionId: workerSessionId,
                modelName: entry.model.displayName,
                workerGroupId: group.id, workerGroupName: group.name, output: "",
                error: "Worker exceeded the \(timeoutSeconds)-second timeout during session setup."
            )
        }

        guard let confirmedRoute = resolvedWorkerConfiguration(for: workerSessionId),
              confirmedRoute.group.id == group.id,
              let confirmedEntry = store.entry(for: confirmedRoute.entryId) else {
            return DelegatedWorkerRunResult(
                status: "error", sessionId: workerSessionId,
                modelName: entry.model.displayName,
                workerGroupId: group.id, workerGroupName: group.name, output: "",
                error: "Worker Group changed before the task could start."
            )
        }
        entry = confirmedEntry
        let boundGroup = confirmedRoute.group
        workerVM.selectedModel = entry.model

        // Overwrite the new-session default binding with the exact worker
        // route resolved above. This is the fail-closed boundary that prevents
        // a concurrent config change from silently running the parent model.
        store.setBinding(SessionModelBinding(
            sessionId: workerSessionId,
            primarySource: .group(groupId: boundGroup.id, resolvedEntryId: confirmedRoute.entryId),
            subModelSource: nil
        ), for: workerSessionId)
        if let level = boundGroup.defaultThinkingLevel {
            var inference = store.inferenceConfig(for: workerSessionId) ?? SessionInferenceConfig()
            inference.thinkingLevel = level
            store.setInferenceConfig(inference, for: workerSessionId)
        }
        await ChatStore.shared.updateSessionModelId(workerSessionId, modelId: entry.model.id)

        // Workers receive only explicit task context, never persistent memory.
        workerVM.memoryEnabled = false
        await ChatStore.shared.setMemoryEnabled(sessionId: workerSessionId, enabled: false)
        let persistedTitle = title.isEmpty ? "Delegated task" : String(title.prefix(80))
        await ChatStore.shared.updateSessionTitle(workerSessionId, title: persistedTitle)
        SessionActivityTracker.shared.updateSessionTitle(workerSessionId, title: persistedTitle)

        var prompt = "Assigned task:\n\(taskText)"
        if !expected.isEmpty {
            prompt += "\n\nExpected output:\n\(expected)"
        }
        prompt += "\n\nReturn the completed result and supporting evidence to the parent agent."

        // Cancellation can arrive during any of the async persistence calls
        // above. It must be observed before the paid provider request starts.
        if Task.isCancelled || userDidCancel {
            workerVM.cancel()
            SessionConcurrencyManager.shared.cancelWait(sessionId: workerSessionId)
            return DelegatedWorkerRunResult(
                status: "cancelled", sessionId: workerSessionId,
                modelName: entry.model.displayName,
                workerGroupId: boundGroup.id, workerGroupName: boundGroup.name,
                output: "", error: "Worker was cancelled before dispatch."
            )
        }
        guard Date() < deadline else {
            workerVM.cancel()
            SessionConcurrencyManager.shared.cancelWait(sessionId: workerSessionId)
            return DelegatedWorkerRunResult(
                status: "timeout", sessionId: workerSessionId,
                modelName: entry.model.displayName,
                workerGroupId: boundGroup.id, workerGroupName: boundGroup.name,
                output: "", error: "Worker exceeded the \(timeoutSeconds)-second timeout before dispatch."
            )
        }
        workerVM.inputText = prompt
        workerVM.send()

        do {
            while workerVM.isProcessing {
                try Task.checkCancellation()
                if Date() >= deadline {
                    workerVM.cancel()
                    SessionConcurrencyManager.shared.cancelWait(sessionId: workerSessionId)
                    return DelegatedWorkerRunResult(
                        status: "timeout", sessionId: workerSessionId,
                        modelName: entry.model.displayName,
                        workerGroupId: boundGroup.id, workerGroupName: boundGroup.name, output: "",
                        error: "Worker exceeded the \(timeoutSeconds)-second timeout and was stopped."
                    )
                }
                let remaining = deadline.timeIntervalSinceNow
                let sleepNanos = UInt64(min(max(remaining, 0.001), 0.2) * 1_000_000_000)
                try await Task.sleep(nanoseconds: sleepNanos)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            workerVM.cancel()
            SessionConcurrencyManager.shared.cancelWait(sessionId: workerSessionId)
            return DelegatedWorkerRunResult(
                status: "cancelled", sessionId: workerSessionId,
                modelName: entry.model.displayName,
                workerGroupId: boundGroup.id, workerGroupName: boundGroup.name,
                output: "", error: "Worker was cancelled and stopped."
            )
        }

        let assistant = workerVM.messages.last(where: { $0.role == .assistant })
        let responseText = assistant?.blocks
            .filter { $0.kind == .text }
            .map(\.content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let failure = assistant?.error ?? workerVM.errorMessage
        if let failure, !failure.isEmpty {
            return DelegatedWorkerRunResult(
                status: "error", sessionId: workerSessionId,
                modelName: entry.model.displayName,
                workerGroupId: boundGroup.id, workerGroupName: boundGroup.name,
                output: responseText,
                error: failure
            )
        }
        guard !responseText.isEmpty else {
            return DelegatedWorkerRunResult(
                status: "error", sessionId: workerSessionId,
                modelName: entry.model.displayName,
                workerGroupId: boundGroup.id, workerGroupName: boundGroup.name, output: "",
                error: "Worker completed without a usable text response."
            )
        }
        return DelegatedWorkerRunResult(
            status: "success", sessionId: workerSessionId,
            modelName: entry.model.displayName,
            workerGroupId: boundGroup.id, workerGroupName: boundGroup.name,
            output: responseText, error: nil
        )
    }

    /// Execute a single tool use, returning a self-contained outcome.
    /// All mutations to `messages[msgIdx].blocks[blockIdx]` happen inside
    /// (the VM is @MainActor so this is safe even when invoked from
    /// concurrent child tasks). The outcome carries the toolResult part,
    /// snapshot, and cancellation flag so the dispatcher can collect them
    /// in original tool_use order after every child task completes.
    func executeSingleToolUse(
        tu: StreamResult.ToolEntry,
        msgIdx: Int,
        tools: [AgentToolDefinition],
        batchBudget: BatchImageBudget
    ) async -> ToolExecOutcome {
        let blockIdx = tu.blockIdx

        // Graceful cancel pre-check: any task that begins after the user
        // tapped Stop short-circuits with a synthetic cancellation result
        // so history stays paired.
        if Task.isCancelled || self.userDidCancel {
            let cancelContent = "<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>"
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].toolStatus = .cancelled
                messages[msgIdx].blocks[blockIdx].content = cancelContent
            }
            let cancelSnap = ToolSnapshot(type: .text, text: cancelContent, mediaRef: nil, duration: nil)
            let item = ToolSnapshotItem(
                id: tu.id, toolName: tu.name, snapshot: cancelSnap,
                mediaResolver: await ChatStore.shared.mediaFileURLResolver()
            )
            return ToolExecOutcome(
                toolId: tu.id, toolName: tu.name,
                resultPart: .toolResult(id: tu.id, name: tu.name, content: cancelContent, isError: true),
                snapshotEntry: (toolName: tu.name, snapshot: cancelSnap),
                snapshotItem: item,
                cancelled: true
            )
        }

        // Fail closed at execution time as well as schema time. Persisted or
        // hallucinated tool calls can bypass schema lookup/preflight, so a
        // delegated session must never reach a mutating native switch case.
        if isDelegatedWorkerSession && !Self.delegatedWorkerToolNames.contains(tu.name) {
            let blocked = "Error: Delegated workers are read-only and cannot execute '\(tu.name)'."
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = blocked
                messages[msgIdx].blocks[blockIdx].toolStatus = .failed(message: blocked)
            }
            let snapshot = ToolSnapshot(type: .text, text: blocked, mediaRef: nil, duration: nil)
            let item = ToolSnapshotItem(
                id: tu.id, toolName: tu.name, snapshot: snapshot,
                mediaResolver: await ChatStore.shared.mediaFileURLResolver()
            )
            return ToolExecOutcome(
                toolId: tu.id, toolName: tu.name,
                resultPart: .toolResult(id: tu.id, name: tu.name, content: blocked, isError: true),
                snapshotEntry: (toolName: tu.name, snapshot: snapshot),
                snapshotItem: item,
                cancelled: false
            )
        }

        var toolOutput: String = ""
        var toolSuccess: Bool = false
        var toolImageData: Data?
        var toolImageMimeType: String?
        var toolImageLinuxPath: String?
        var toolPageURL: String?
        var cancelledHere = false

        // Loop-detector pre-check: short-circuit when the model is stuck
        // in a runaway pattern (unknown tool spam, no-progress polling, etc).
        let loopPreCheck = toolLoopDetector.check(toolName: tu.name, params: tu.args)
        if loopPreCheck.level == .critical, let blockedMsg = loopPreCheck.message {
            toolOutput = blockedMsg
            toolSuccess = false
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = blockedMsg
                messages[msgIdx].blocks[blockIdx].toolStatus = .failed(message: "loop blocked")
            }
            toolLoopDetector.record(
                toolName: tu.name, params: tu.args,
                result: nil, errorMessage: blockedMsg, toolCallId: tu.id
            )
            let blockedSnap = ToolSnapshot(type: .text, text: blockedMsg, mediaRef: nil, duration: nil)
            let item = ToolSnapshotItem(
                id: tu.id, toolName: tu.name, snapshot: blockedSnap,
                mediaResolver: await ChatStore.shared.mediaFileURLResolver()
            )
            return ToolExecOutcome(
                toolId: tu.id, toolName: tu.name,
                resultPart: .toolResult(id: tu.id, name: tu.name, content: blockedMsg, isError: true),
                snapshotEntry: (toolName: tu.name, snapshot: blockedSnap),
                snapshotItem: item,
                cancelled: false
            )
        }

        // JSON Repair (T-tool-json-repair b2c4f8a6).
        var toolArgs: [String: Any] = tu.args
        let needsRepair: Bool = {
            guard let toolDef = tools.first(where: { $0.name == tu.name }) else { return false }
            if tu.args.isEmpty && !toolDef.required.isEmpty { return true }
            for field in toolDef.required {
                guard let raw = tu.args[field] else { return true }
                if raw is NSNull { return true }
                if let s = raw as? String,
                   s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                if !(raw is String) && !(raw is [Any]) && !(raw is [String: Any]) { return true }
            }
            return false
        }()
        if needsRepair {
            let rawJoined = tu.inputChunkRing.joined()
            let repairOutcome = Self.repairToolArgs(
                name: tu.name, args: tu.args, rawTail: rawJoined, tools: tools
            )
            if !repairOutcome.repairs.isEmpty {
                AppLogger(category: "ToolPreflight").warning(
                    "[ToolRepair] REPAIRED tool=\(tu.name) id=\(tu.id) strategies=[\(repairOutcome.repairs.joined(separator: ", "))] beforeKeys=[\(tu.args.keys.sorted().joined(separator: ","))] afterKeys=[\(repairOutcome.args.keys.sorted().joined(separator: ","))] rawJoined=<<<\(rawJoined.prefix(500))>>>"
                )
                toolArgs = repairOutcome.args
            }
        }

        // Preflight: reject empty / missing-required-field tool calls.
        if let preflightError = Self.preflightValidateToolCall(name: tu.name, args: toolArgs, tools: tools) {
            let chunkRing = tu.inputChunkRing
            AppLogger(category: "ToolPreflight").warning(
                "[ToolPreflight] BLOCKED tool=\(tu.name) id=\(tu.id) reason=\"\(preflightError)\" argsKeys=[\(tu.args.keys.sorted().joined(separator: ","))] chunkCount=\(chunkRing.count) lastChunk=<<<\(chunkRing.last?.prefix(500) ?? "")>>>"
            )
            let uiMessage = String(localized: "Blocked invalid tool call")
            let modelMessage = "Error: Tool call rejected before execution. \(preflightError) The arguments your client sent were empty or missing required fields — re-issue the call with all required parameters filled in. Do not retry with the same empty arguments."
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = uiMessage
                messages[msgIdx].blocks[blockIdx].toolStatus = .failed(message: uiMessage)
            }
            toolLoopDetector.record(
                toolName: tu.name, params: tu.args,
                result: nil, errorMessage: modelMessage, toolCallId: tu.id
            )
            let blockedSnap = ToolSnapshot(type: .text, text: modelMessage, mediaRef: nil, duration: nil)
            let item = ToolSnapshotItem(
                id: tu.id, toolName: tu.name, snapshot: blockedSnap,
                mediaResolver: await ChatStore.shared.mediaFileURLResolver()
            )
            return ToolExecOutcome(
                toolId: tu.id, toolName: tu.name,
                resultPart: .toolResult(id: tu.id, name: tu.name, content: modelMessage, isError: true),
                snapshotEntry: (toolName: tu.name, snapshot: blockedSnap),
                snapshotItem: item,
                cancelled: false
            )
        }

        let argsJson: String = {
            if let data = try? JSONSerialization.data(withJSONObject: toolArgs),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{}"
        }()

        do {
        switch tu.name {
        case "delegate_task":
            let delegation = try await executeDelegatedWorker(arguments: toolArgs)
            toolOutput = delegation.jsonString()
            toolSuccess = delegation.success
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = toolOutput
            }

        case "shell_execute":
            let (command, timeout, delay) = parseToolInput(from: argsJson)

            if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ctLogger.warning("[ToolArgsProbe] shell_execute called with empty command — argsJson=<<<\(argsJson)>>>")
                toolOutput = "Error: Missing required 'command' parameter. Please call shell_execute again with a non-empty `command` field."
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
                break
            }

            // Offload permission check.
            ctLogger.info("[OffloadPerm] shell command: \(command)")
            if let offloadCmd = OffloadPermissionManager.extractOffloadCommand(from: command) {
                ctLogger.info("[OffloadPerm] matched offload: \(offloadCmd), level: \(OffloadPermissionManager.shared.permissionLevel(for: offloadCmd).rawValue)")
                let permResult = await OffloadPermissionManager.shared.checkPermission(
                    for: offloadCmd, sessionId: self.sessionId, fullCommand: command
                )
                if case .denied(let msg) = permResult {
                    ctLogger.info("[OffloadPerm] DENIED: \(offloadCmd)")
                    toolOutput = msg
                    toolSuccess = false
                    if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                        messages[msgIdx].blocks[blockIdx].content = msg
                    }
                    break
                }
                ctLogger.info("[OffloadPerm] ALLOWED: \(offloadCmd)")
            } else {
                ctLogger.info("[OffloadPerm] no offload match for first token")
            }

            // Delay execution.
            if delay > 0 {
                toolDelayWaitCount += 1
                defer { toolDelayWaitCount -= 1 }
                // [T-delay-stop-latency] The stop button during the countdown
                // sets `commandCancelledByUser` (stopCurrentCommand guards on
                // `toolDelayWaitActive`), but the old loop only re-checked that
                // flag once per whole second and then slept a FULL second — a
                // tap landing just after a check waited up to ~1s before the
                // next check, which read as "stop does nothing" during the
                // delay phase (the user report). Poll on a short tick instead so
                // both the button flag AND Task cancellation are honored within
                // ~100ms, while the visible countdown still refreshes once per
                // whole second.
                let totalSeconds = Int(delay)
                let tickNanos: UInt64 = 100_000_000 // 100ms
                let ticksPerSecond = 10
                var lastShownRemaining = -1
                for tick in 0..<(totalSeconds * ticksPerSecond) {
                    if commandCancelledByUser || Task.isCancelled {
                        throw CancellationError()
                    }
                    let remaining = totalSeconds - (tick / ticksPerSecond)
                    if remaining != lastShownRemaining,
                       msgIdx < self.messages.count, blockIdx < self.messages[msgIdx].blocks.count {
                        lastShownRemaining = remaining
                        let mm = remaining / 60
                        let ss = remaining % 60
                        let countdown = mm > 0 ? String(format: "%d:%02d", mm, ss) : "\(ss)s"
                        self.messages[msgIdx].blocks[blockIdx].content = "⏳ Waiting \(countdown) before executing..."
                        self.scrollToBottomSignal.send()
                    }
                    try await Task.sleep(nanoseconds: tickNanos)
                }
                // Final cancellation check after the last tick so a tap in the
                // final 100ms window still aborts before we launch the process.
                if commandCancelledByUser || Task.isCancelled {
                    throw CancellationError()
                }
            }

            let preSnapshot = snapshotMinisFiles()
            let result: CommandResult
            do {
                var lineBuffer: [String] = []
                var lastFlush = Date.distantPast
                let kMaxStreamingDisplayChars = 30_000
                let flushLines: () -> Void = { [weak self] in
                    guard let self, !lineBuffer.isEmpty else { return }
                    let joined = lineBuffer.joined(separator: "\n")
                    lineBuffer.removeAll()
                    lastFlush = Date()
                    if msgIdx < self.messages.count && blockIdx < self.messages[msgIdx].blocks.count {
                        let current = self.messages[msgIdx].blocks[blockIdx].content
                        var newContent: String
                        if current.hasSuffix("Executing...") {
                            newContent = joined
                        } else {
                            newContent = current + "\n" + joined
                        }
                        if newContent.count > kMaxStreamingDisplayChars {
                            newContent = "…[output truncated]…\n" + String(newContent.suffix(kMaxStreamingDisplayChars))
                        }
                        self.messages[msgIdx].blocks[blockIdx].content = newContent
                        self.scrollToBottomSignal.send()
                    }
                }
                result = try await executeCommand(command, timeout: timeout) { [weak self] line in
                    guard let self else { return }
                    let (cleanedLine, capturedURLs) = MinisURLMarker.extract(from: line)
                    if !capturedURLs.isEmpty {
                        Task { @MainActor in
                            for raw in capturedURLs {
                                if let u = URL(string: raw),
                                   MinisOpenURLBroker.isSupportedScheme(u.scheme) {
                                    MinisOpenURLBroker.shared.offer(u)
                                }
                            }
                        }
                    }
                    if cleanedLine.isEmpty && !line.isEmpty { return }
                    lineBuffer.append(cleanedLine)
                    if Date().timeIntervalSince(lastFlush) >= 0.2 {
                        flushLines()
                    }
                }
                flushLines()
            } catch {
                result = CommandResult(output: "Error: \(error.localizedDescription)", exitCode: -1)
            }
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                let existingContent = messages[msgIdx].blocks[blockIdx].content
                let hasStreamedContent = !existingContent.isEmpty
                    && !existingContent.hasSuffix("Executing...")
                if !hasStreamedContent {
                    let (cleaned, capturedURLs) = MinisURLMarker.extract(from: result.output)
                    for raw in capturedURLs {
                        if let u = URL(string: raw),
                           MinisOpenURLBroker.isSupportedScheme(u.scheme) {
                            MinisOpenURLBroker.shared.offer(u)
                        }
                    }
                    let resultTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !resultTrimmed.isEmpty {
                        messages[msgIdx].blocks[blockIdx].content = resultTrimmed
                    }
                }
            }
            if commandCancelledByUser {
                // NOTE: don't reset commandCancelledByUser here under
                // concurrent execution — sibling shell tasks still need
                // the signal to abort their own delay loops. The outer
                // dispatcher resets it once per batch.
                toolOutput = "<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>\n" + result.output
                cancelledHere = true
            } else {
                toolOutput = result.output
            }
            toolSuccess = result.exitCode == 0

            // Scan for new/modified files under /var/minis/
            let postSnapshot = snapshotMinisFiles()
            let newOrModified = postSnapshot.filter { key, date in
                preSnapshot[key] == nil || preSnapshot[key]! < date
            }
            if !newOrModified.isEmpty {
                for (path, _) in newOrModified {
                    var isDir: ObjCBool = false
                    if let hostURL = resolveHostPath(path) {
                        FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDir)
                    }
                    ensureParentDirsInMetaDB(for: path)
                    ensureFakefsMetadata(for: path, isDirectory: isDir.boolValue)
                }
                toolOutput += "\n\n[minis] New/modified files:"
                for path in newOrModified.keys.sorted() {
                    if let url = linuxPathToMinisURL(path) {
                        toolOutput += "\n  \(url)"
                    }
                }
            }

            let (redactedOut, redactHits) = EnvVarRedactor.redactIfEnabled(toolOutput)
            if redactHits > 0 {
                ctLogger.info("[EnvVarRedact] shell_execute: masked \(redactHits) env-var value(s) in tool result")
            }
            toolOutput = redactedOut

        case "file_read":
            let requestedPath = toolArgs["path"] as? String ?? ""
            if isDelegatedWorkerSession && !Self.delegatedWorkerMayRead(path: requestedPath) {
                toolOutput = "Error: Delegated workers may read only task artifacts under approved /var/minis workspace namespaces. Memory, skills, credentials, and other paths are blocked."
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
                break
            }
            let fileResult: FileToolResult
            do {
                fileResult = try await executeFileRead(from: argsJson)
            } catch {
                fileResult = FileToolResult(output: "Error: \(error.localizedDescription)", success: false)
            }
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = fileResult.output
            }
            toolOutput = fileResult.output
            toolSuccess = fileResult.success
            if fileResult.success,
               let data = argsJson.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let readPath = dict["path"] as? String,
               let skillId = SkillStore.shared.skillIdFromPath(readPath) {
                await MainActor.run { SkillStore.shared.recordSkillUse(skillId) }
            }

        case "file_write":
            let fileResult: FileToolResult
            do {
                fileResult = try await executeFileWrite(from: argsJson)
            } catch {
                fileResult = FileToolResult(output: "Error: \(error.localizedDescription)", success: false)
            }
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = fileResult.output
            }
            toolOutput = fileResult.output
            toolSuccess = fileResult.success
            if fileResult.success,
               let data = argsJson.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let writtenPath = dict["path"] as? String,
               writtenPath.contains("/skills/") && writtenPath.hasSuffix("SKILL.md") {
                await MainActor.run { SkillStore.shared.reload() }
            }

        case "file_edit":
            let fileResult: FileToolResult
            do {
                fileResult = try await executeFileEdit(from: argsJson)
            } catch {
                fileResult = FileToolResult(output: "Error: \(error.localizedDescription)", success: false)
            }
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = fileResult.output
            }
            toolOutput = fileResult.output
            toolSuccess = fileResult.success
            if fileResult.success,
               let data = argsJson.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let editedPath = dict["path"] as? String,
               editedPath.contains("/skills/") && editedPath.hasSuffix("SKILL.md") {
                await MainActor.run { SkillStore.shared.reload() }
            }

        case "browser_use":
            var browserResult: BrowserActionResult
            if let input = BrowserActionInput.parse(from: argsJson) {
                if isDelegatedWorkerSession
                    && !Self.delegatedWorkerBrowserActions.contains(input.action) {
                    browserResult = .error(
                        "Delegated workers cannot perform browser action '\(input.action.rawValue)'."
                    )
                } else if isDelegatedWorkerSession,
                          input.action == .navigate,
                          !Self.delegatedWorkerMayNavigate(to: input.url) {
                    browserResult = .error(
                        "Delegated workers may navigate only to absolute http:// or https:// URLs. Local, data, file, Minis, and action schemes are blocked."
                    )
                } else {
                    do {
                        browserResult = try await browserTabPool.execute(action: input)
                    } catch {
                        browserResult = .error(error.localizedDescription)
                    }
                }
            } else {
                browserResult = .error("Invalid browser_use input. Required: 'action' parameter.")
            }

            if browserTakeoverActive {
                if let freshResult = await waitForMidActionTakeover() {
                    let originalText = browserResult.text
                    let takeoverNote = "\n[Browser takeover] User manually operated the browser. Screenshot updated."
                    browserResult = BrowserActionResult(
                        text: originalText + takeoverNote,
                        success: browserResult.success,
                        base64Image: freshResult.base64Image,
                        imageFilePath: freshResult.imageFilePath,
                        pageURL: freshResult.pageURL ?? browserResult.pageURL
                    )
                }
            }
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = browserResult.text
                messages[msgIdx].blocks[blockIdx].imageFilePath = browserResult.imageFilePath
                if let pageURL = browserResult.pageURL {
                    messages[msgIdx].blocks[blockIdx].browserURL = pageURL
                }
            }
            toolOutput = browserResult.text
            toolSuccess = browserResult.success
            toolPageURL = browserResult.pageURL
            if let b64 = browserResult.base64Image, let data = Data(base64Encoded: b64) {
                toolImageData = Self.resizedImageData(data, maxLongEdge: 2000) ?? data
                toolImageMimeType = "image/jpeg"

                let timestamp = Int(Date().timeIntervalSince1970)
                let screenshotFilename = "screenshot_\(timestamp).jpg"
                let sid = sessionId ?? "unknown"
                let persistDir = Self.minisBrowserPersistentDir(for: sid)
                let fm = FileManager.default
                try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)
                let persistPath = persistDir.appendingPathComponent(screenshotFilename)
                try? data.write(to: persistPath)

                let linuxPath = "\(Self.minisBrowserLinuxDir)/\(screenshotFilename)"
                toolImageLinuxPath = linuxPath

                if let minisURL = linuxPathToMinisURL(linuxPath) {
                    toolOutput += "\nminis_url: \(minisURL)"
                }
            }

            if let fetchData = browserResult.fetchedFileData,
               let fetchName = browserResult.fetchedFileName {
                let sid = sessionId ?? "unknown"
                let persistDir = Self.minisBrowserPersistentDir(for: sid)
                try? FileManager.default.createDirectory(at: persistDir, withIntermediateDirectories: true)
                let persistPath = persistDir.appendingPathComponent(fetchName)
                try? fetchData.write(to: persistPath)

                let linuxPath = "\(Self.minisBrowserLinuxDir)/\(fetchName)"
                if let minisURL = linuxPathToMinisURL(linuxPath) {
                    toolOutput += "\nminis_url: \(minisURL)"
                }
            }

            // [T-browser-download-ux] Surface native WKDownload activity in the
            // tool result so the agent KNOWS a page interaction triggered a
            // download and doesn't re-download the same file via shell
            // curl/wget. WebKit's decideDestination callback can land a beat
            // after the action resolves (navigation-turned-download resumes
            // the continuation first), so if a download is in flight but not
            // yet registered, wait briefly for the filename to be known.
            if let sid = sessionId {
                var downloadReport = BrowserDownloadCenter.shared.agentReport(for: sid)
                if downloadReport == nil,
                   browserTabPool.activeManager?.hasInflightDownloads == true {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    downloadReport = BrowserDownloadCenter.shared.agentReport(for: sid)
                        ?? "[browser_downloads] This action triggered a native browser file "
                         + "download that is still starting (filename not yet resolved). It will "
                         + "be saved into /var/minis/workspace/ — do NOT re-download it with "
                         + "curl/wget; check the workspace or the next browser_use result instead."
                }
                if let downloadReport {
                    toolOutput += "\n\n" + downloadReport
                }
            }

        case "read_image":
            let pathArg = toolArgs["path"] as? String ?? ""
            if isDelegatedWorkerSession && !Self.delegatedWorkerMayRead(path: pathArg) {
                toolOutput = "Error: Delegated workers may inspect images only under approved /var/minis workspace namespaces."
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
                break
            }
            let resolvedURL = await resolveMinisPath(pathArg)
            if isDelegatedWorkerSession,
               let resolvedURL,
               !delegatedWorkerResolvedReadURLIsAllowed(resolvedURL, requestedPath: pathArg) {
                toolOutput = "Error: Resolved image escapes this worker session's allowed roots."
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
                break
            }
            ctLogger.info("[read_image] pathArg=\(pathArg) resolvedURL=\(resolvedURL?.path ?? "nil") exists=\(resolvedURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
            if let resolvedURL {
                let dataOK = (try? Data(contentsOf: resolvedURL)) != nil
                let uiOK = (try? Data(contentsOf: resolvedURL)).flatMap { UIImage(data: $0) } != nil
                ctLogger.info("[read_image] dataReadable=\(dataOK) uiImageDecodable=\(uiOK) fileSize=\((try? FileManager.default.attributesOfItem(atPath: resolvedURL.path)[.size]) ?? "?")")
            }

            if let fileURL = resolvedURL,
               let fileData = try? Data(contentsOf: fileURL),
               let uiImage = UIImage(data: fileData) {
                let originalSize = fileData.count
                let originalW = uiImage.cgImage.map { $0.width } ?? Int(uiImage.size.width)
                let originalH = uiImage.cgImage.map { $0.height } ?? Int(uiImage.size.height)

                let inferenceData: Data
                let resizedW: Int
                let resizedH: Int
                if let resized = Self.resizedImageData(fileData, maxLongEdge: 2000),
                   let resizedImage = UIImage(data: resized) {
                    inferenceData = resized
                    resizedW = resizedImage.cgImage.map { $0.width } ?? Int(resizedImage.size.width)
                    resizedH = resizedImage.cgImage.map { $0.height } ?? Int(resizedImage.size.height)
                } else {
                    inferenceData = uiImage.jpegData(compressionQuality: 0.85) ?? fileData
                    resizedW = originalW
                    resizedH = originalH
                }

                toolImageData = inferenceData
                toolImageMimeType = "image/jpeg"
                if pathArg.hasPrefix("/var/minis/") {
                    toolImageLinuxPath = pathArg
                } else if pathArg.hasPrefix("minis://") {
                    let tail = String(pathArg.dropFirst("minis://".count))
                    if !tail.isEmpty {
                        toolImageLinuxPath = "/var/minis/\(tail)"
                    }
                }

                var meta = "Image loaded successfully."
                meta += "\nPath: \(pathArg)"
                meta += "\nOriginal: \(originalW)x\(originalH), \(formatBytes(originalSize))"
                if resizedW != originalW || resizedH != originalH {
                    meta += "\nResized for analysis: \(resizedW)x\(resizedH)"
                }
                meta += "\nMIME: image/jpeg"
                toolOutput = meta
                toolSuccess = true

                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].imageFilePath = fileURL.path
                    messages[msgIdx].blocks[blockIdx].content = meta
                }
            } else {
                ctLogger.error("[read_image] FAILED pathArg=\(pathArg) resolvedURL=\(resolvedURL?.path ?? "nil")")
                toolOutput = "Error: Could not read image at '\(pathArg)'. Verify the path exists and is a valid image file."
                toolSuccess = false
            }

        case "memory_write":
            let memResult = executeMemoryWrite(from: argsJson)
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = memResult.output
            }
            toolOutput = memResult.output
            toolSuccess = memResult.success

        case "memory_get":
            let memResult = executeMemoryGet(from: argsJson)
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = memResult.output
            }
            toolOutput = memResult.output
            toolSuccess = memResult.success

        default:
            toolOutput = "Error: Unknown tool '\(tu.name)'"
            toolSuccess = false
        }
        } catch is CancellationError {
            let cancelContent = "<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>"
            let existing = (msgIdx < messages.count && blockIdx < messages[msgIdx].blocks.count)
                ? messages[msgIdx].blocks[blockIdx].content : ""
            toolOutput = existing.isEmpty ? cancelContent : existing + "\n" + cancelContent
            toolSuccess = false
            cancelledHere = true
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].toolStatus = .cancelled
            }
        } catch {
            ctLogger.error("Tool execution threw non-cancellation error: \(error)")
            toolOutput = "Error: \(error.localizedDescription)"
            toolSuccess = false
        }

        // Tail cancel-detection: if Task got cancelled mid-execution.
        if !cancelledHere && Task.isCancelled && self.userDidCancel {
            cancelledHere = true
            toolOutput += "\n<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>"
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = toolOutput
                messages[msgIdx].blocks[blockIdx].toolStatus = .cancelled
            }
        }

        let toolDuration: TimeInterval? = {
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count,
               let start = messages[msgIdx].blocks[blockIdx].toolStartTime {
                return Date().timeIntervalSince(start)
            }
            return nil
        }()

        // Create snapshot from tool output.
        let snapshot: ToolSnapshot
        switch tu.name {
        case "browser_use":
            if let imagePath = (msgIdx < messages.count && blockIdx < messages[msgIdx].blocks.count)
                ? messages[msgIdx].blocks[blockIdx].imageFilePath : nil,
               let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
               let sid = sessionId {
                let ref = await ChatStore.shared.saveMedia(
                    data: imageData, mimeType: "image/jpeg", sessionId: sid,
                    originalFileName: "browser_snapshot.jpg", subdir: "browser",
                    linuxPath: toolImageLinuxPath
                )
                snapshot = ToolSnapshot(type: .image, text: nil, mediaRef: ref, duration: toolDuration)
            } else {
                let lines = toolOutput.components(separatedBy: "\n")
                let lastLines = lines.suffix(20).joined(separator: "\n")
                snapshot = ToolSnapshot(type: .text, text: lastLines, mediaRef: nil, duration: toolDuration)
            }
        case "read_image":
            if let imagePath = (msgIdx < messages.count && blockIdx < messages[msgIdx].blocks.count)
                ? messages[msgIdx].blocks[blockIdx].imageFilePath : nil,
               let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
               let sid = sessionId {
                let fileURL = URL(fileURLWithPath: imagePath)
                let mime = Self.detectImageMime(imageData)
                let ref = await ChatStore.shared.saveMedia(
                    data: imageData, mimeType: mime, sessionId: sid,
                    originalFileName: fileURL.lastPathComponent, subdir: "images",
                    linuxPath: toolImageLinuxPath
                )
                snapshot = ToolSnapshot(type: .image, text: nil, mediaRef: ref, duration: toolDuration)
            } else {
                snapshot = ToolSnapshot(type: .text, text: toolOutput, mediaRef: nil, duration: toolDuration)
            }
        case "file_write", "file_edit":
            if let path = toolArgs["path"] as? String,
               let hostURL = await resolvePathForDirectRead(path),
               let fileContent = try? String(contentsOf: hostURL, encoding: .utf8) {
                let lines = fileContent.components(separatedBy: "\n")
                let preview = lines.prefix(200).joined(separator: "\n")
                snapshot = ToolSnapshot(type: .text, text: preview, mediaRef: nil, duration: toolDuration)
            } else {
                snapshot = ToolSnapshot(type: .text, text: toolOutput, mediaRef: nil, duration: toolDuration)
            }
        default:
            snapshot = ToolSnapshot(type: .text, text: toolOutput, mediaRef: nil, duration: toolDuration)
        }

        let snapshotResolver = await ChatStore.shared.mediaFileURLResolver()
        let snapshotItem = ToolSnapshotItem(
            id: tu.id, toolName: tu.name, snapshot: snapshot, mediaResolver: snapshotResolver
        )

        // Update tool block status and store execution duration.
        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            let blk = messages[msgIdx].blocks[blockIdx]
            blk.toolDuration = toolDuration
            if cancelledHere {
                blk.toolStatus = .cancelled
            } else {
                blk.toolStatus = toolSuccess
                    ? .success
                    : .failed(message: toolOutput.components(separatedBy: "\n").first ?? "Failed")
            }
            ctLogger.info("[ToolLifecycle] COMPLETED toolId=\(tu.id.prefix(20)) tool=\(tu.name) sid=\(sessionId?.prefix(8) ?? "nil") appState=\(UIApplication.shared.applicationState == .active ? "fg" : "bg") suspended=\(streamingUIUpdatesSuspended) isProcessing=\(isProcessing) success=\(toolSuccess) duration=\(String(format: "%.1f", toolDuration ?? 0))s")
            scrollToBottomSignal.send()
        }

        // Compose finalOutput with truncation/offload.
        let maxToolResultLength = Self.kMaxToolResultChars
        var finalOutput: String
        if toolOutput.isEmpty {
            finalOutput = "(no output)"
        } else if toolOutput.count > maxToolResultLength {
            let offloadResult = offloadToolOutput(toolOutput, toolName: tu.name, toolId: tu.id)
            let offloadMinisURL = linuxPathToMinisURL(offloadResult.linuxPath)
            let truncatedBody: String
            if tu.name == "shell_execute" || tu.name == "browser_use" {
                let halfLen = maxToolResultLength / 2
                truncatedBody = String(toolOutput.prefix(halfLen))
                    + "\n\n...\n\n"
                    + String(toolOutput.suffix(halfLen))
            } else {
                truncatedBody = String(toolOutput.prefix(maxToolResultLength))
            }
            finalOutput = truncatedBody
                + "\n\n[OUTPUT TRUNCATED] Full output (\(toolOutput.count) chars) saved to: \(offloadResult.linuxPath)"
                + (offloadMinisURL.map { "\nminis_url: \($0)" } ?? "")
                + "\nUse file_read tool to read the complete output."
        } else {
            finalOutput = toolOutput
        }

        // Image budget: reserve a slot atomically via the actor. If
        // declined, swap image bytes for a text placeholder.
        if let imgData = toolImageData {
            let granted = await batchBudget.reserveSlot()
            if !granted {
                let placeholder = Self.imagePlaceholderText(data: imgData, originalPath: toolArgs["path"] as? String, snapshotPath: nil)
                if finalOutput.isEmpty || !toolSuccess {
                    finalOutput = placeholder
                } else {
                    finalOutput += "\n\n" + placeholder
                }
                toolImageData = nil
                toolImageMimeType = nil
                ctLogger.info("🖼️ Tool image budget exhausted, stripped image from \(tu.name) id:\(tu.id.prefix(8))")
            }
        }

        // Loop-detector post-record.
        let postCheck = toolLoopDetector.record(
            toolName: tu.name, params: toolArgs,
            result: toolSuccess ? finalOutput : nil,
            errorMessage: toolSuccess ? nil : finalOutput,
            toolCallId: tu.id
        )
        if postCheck.level == .warning, let warningMsg = postCheck.message {
            if finalOutput.isEmpty {
                finalOutput = warningMsg
            } else {
                finalOutput += "\n\n" + warningMsg
            }
        }

        let resultPart = AgentContentPart.toolResult(
            id: tu.id, name: tu.name, content: finalOutput, isError: !toolSuccess,
            imageData: toolImageData, imageMimeType: toolImageMimeType,
            pageURL: toolPageURL, imageLinuxPath: toolImageLinuxPath
        )

        #if DEBUG
        let head = String(finalOutput.prefix(200))
        let tail = finalOutput.count > 400 ? "...\(String(finalOutput.suffix(200)))" : ""
        ctLogger.debug("🔧 Tool result [\(tu.name)] id:\(tu.id.prefix(8)) success:\(toolSuccess) len:\(finalOutput.count) head=\"\(head)\" \(tail)")
        #endif

        return ToolExecOutcome(
            toolId: tu.id, toolName: tu.name,
            resultPart: resultPart,
            snapshotEntry: (toolName: tu.name, snapshot: snapshot),
            snapshotItem: snapshotItem,
            cancelled: cancelledHere
        )
    }
}
