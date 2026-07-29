import Foundation
import UIKit

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Background Task + Background Status Timer

extension AIChatViewModel {

    // MARK: - Background Task

    func beginBackgroundProcessing(resumingAfterExpiration: Bool = false) {
        // An expired finite assertion may already have an invalid identifier
        // while the same logical processing cycle continues under audio or
        // location. Normal call sites must not re-arm the exhausted app budget
        // in that state. A user-driven foreground resume is different: the app
        // has received a new foreground execution window, so it may establish
        // the finite assertion needed for a later background transition without
        // starting a second logical completion cycle.
        guard backgroundTaskID == .invalid else { return }
        guard !backgroundProcessingCompletionPending || resumingAfterExpiration else { return }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingStr = remaining > 99999 ? "unlimited" : String(format: "%.1fs", remaining)
        let sessions = SessionActivityTracker.shared.activeSessions.count
        logger.info("[BKA][BGTask] Beginning 'AgentLoop' remaining=\(remainingStr) sessions=\(sessions)")
        backgroundSuspended = false
        backgroundProcessingCompletionPending = true
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AgentLoop") { [weak self] in
            guard let self else { return }
            let expRemaining = UIApplication.shared.backgroundTimeRemaining
            let expRemainingStr = expRemaining > 99999 ? "unlimited" : String(format: "%.1fs", expRemaining)
            let keepAlive = BackgroundKeepAliveManager.shared
            let hasRuntimeSurvivalLeg = keepAlive.hasRuntimeBackgroundSurvivalLeg
            logger.warning("[BKA][BGTask] Expiry handler fired — id=\(self.backgroundTaskID.rawValue) remaining=\(expRemainingStr) sessions=\(SessionActivityTracker.shared.activeSessions.count) configured=\(keepAlive.enhancedBackgroundEffective) runtimeLegs={\(keepAlive.runtimeBackgroundSurvivalLegDescription)}")

            // Expiration handlers get only a very small cleanup window. End the
            // expiring identifier synchronously before doing shell or model
            // cleanup; endBackgroundProcessing() performs asynchronous Live
            // Activity work and is therefore not safe as the only expiry end.
            let expiringId = self.backgroundTaskID
            self.backgroundTaskID = .invalid
            self.stopBackgroundStatusTimer()
            if expiringId != .invalid {
                UIApplication.shared.endBackgroundTask(expiringId)
            }

            // The FINITE UIApplication background task is separate from the
            // long-lived audio/location background modes. Its budget belongs
            // to the app, not to an individual identifier, so beginning another
            // task here does not reset the exhausted budget and can create an
            // expiry/re-arm loop. We already ended the assertion above. If a
            // real runtime survival leg is alive, simply let the agent continue
            // under that leg.
            if hasRuntimeSurvivalLeg {
                logger.info("[Background] Finite task ended; live runtime survival leg remains — continuing without re-arm")
                return
            }
            // No keep-alive backing us — the system really will terminate the
            // app. Suspend instead of cancelling: kill the running shell command
            // so the OS doesn't terminate us, but keep the Task alive so we can
            // resume when foregrounded.
            logger.warning("[Background] Task expiring (no live runtime survival leg) — suspending agent loop")
            self.backgroundSuspended = true
            BackgroundInterruptionTracker.shared.recordInterruption()
            // [T-session-paused-badge-active-false-positive] The PAUSED badge
            // is now driven solely by `canResume` (see AIChatViewModel's
            // canResume didSet) — the authoritative interrupted flag — so it
            // tracks genuine interruption + resolution uniformly. No explicit
            // push here: a background-suspended in-flight loop sets canResume
            // on the next session load / cleanup, which raises the badge.
            // [T-tool-bg-suspended-hint] Stamp the tool blocks that are
            // in-flight RIGHT NOW — these are the ones the OS is about to
            // suspend. They'll be force-finalized to .cancelled (here via
            // stopCurrentCommand / later via the safety net or session
            // reload); the flag lets the chat capsule show the yellow ⓘ
            // hint only for genuine background suspensions.
            for msg in self.messages where msg.role == .assistant {
                for block in msg.blocks {
                    switch block.toolStatus {
                    case .streaming, .running:
                        block.wasBackgroundSuspended = true
                    default:
                        break
                    }
                }
            }
            self.stopCurrentCommand()
        }
        logger.info("[BKA][BGTask] started id=\(self.backgroundTaskID.rawValue) sessions=\(sessions)")
        startBackgroundStatusTimer()
    }

    func endBackgroundProcessing() {
        // [T-ios-session-unread-badge / T-ios-unread-dot-reappears] Mark unread
        // when this session finished off-screen and produced NEW content. The
        // red dot means "this session finished and you haven't opened it yet".
        //
        // This funnel is hit from ~15 sites (normal completions, kernel-failure
        // early-returns, cancel cleanup, the bgTask-expiration handler,
        // resumeQueueAfterCancel, …). Pushing unconditionally re-added the dot
        // on late/duplicate calls that carried no new content — e.g. the user
        // reads and leaves the session, then a background keep-alive bgTask
        // expires and its handler calls endBackgroundProcessing(), re-badging a
        // session the user already read. Gate on the assistant-turn count
        // actually having grown since we last badged, so only a run that truly
        // produced a new assistant completion re-marks unread.
        if let sid = sessionId, !sid.isEmpty {
            let assistantTurns = agentHistory.reduce(0) { $0 + ($1.role == .assistant ? 1 : 0) }
            let hasNewCompletion = assistantTurns > lastBadgedAssistantTurnCount
            if Self.activeSessionId == sid {
                // User is looking at this session right now — they see the
                // completion, so never badge, but DO advance the baseline so a
                // later off-screen call for this same turn can't re-badge it.
                lastBadgedAssistantTurnCount = max(lastBadgedAssistantTurnCount, assistantTurns)
            } else if hasNewCompletion {
                lastBadgedAssistantTurnCount = assistantTurns
                SessionBadgeStore.shared.pushFront(.unread, for: sid)
            }
        }

        // Completion is a logical processing-cycle event, not the lifetime of
        // the finite UIKit assertion. The assertion may already have expired
        // and been ended while a healthy audio/location leg kept work alive.
        guard backgroundProcessingCompletionPending else { return }
        backgroundProcessingCompletionPending = false
        stopBackgroundStatusTimer()
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingStr = remaining > 99999 ? "unlimited" : String(format: "%.1fs", remaining)
        let assertionDescription = backgroundTaskID == .invalid
            ? "already-ended"
            : String(backgroundTaskID.rawValue)
        logger.info("[BKA][BGTask] Completing assertion=\(assertionDescription) remaining=\(remainingStr) sessions=\(SessionActivityTracker.shared.activeSessions.count) silentAudio=\(BackgroundKeepAliveManager.shared.silentAudioIsPlaying)")

        // Post local notification if task completed in background.
        // Await Live Activity "completed" state update BEFORE posting the
        // notification so the lock-screen capsule shows the checkmark when
        // the notification arrives, not "Responding · streaming".
        do {
            let sid = sessionId ?? ""
            let wasBackground = UIApplication.shared.applicationState != .active
            let hasError = messages.last?.error != nil || errorMessage != nil
            let responseSummary: String = {
                let assistantTurns = agentHistory.filter { $0.role == .assistant }
                logger.info("[BackgroundNotification] building responseSummary from agentHistory: totalMsgs=\(agentHistory.count) assistantTurns=\(assistantTurns.count) wasBackground=\(wasBackground) hasError=\(hasError)")

                func textFromTurn(_ msg: AgentMessage) -> String {
                    let raw = msg.parts.compactMap { part -> String? in
                        if case .text(let t) = part { return t }
                        return nil
                    }.joined(separator: "\n")
                    return MarkdownStripper.plainText(raw)
                }

                func hasToolUse(_ msg: AgentMessage) -> Bool {
                    msg.parts.contains { if case .toolUse = $0 { return true }; return false }
                }

                for (idx, msg) in assistantTurns.enumerated() {
                    let hasTools = hasToolUse(msg)
                    let txt = textFromTurn(msg)
                    let preview = String(txt.prefix(20)).replacingOccurrences(of: "\n", with: "↵")
                    logger.info("[BackgroundNotification] agentTurns[\(idx)] hasToolUse=\(hasTools) textLen=\(txt.count) textPreview=\(preview.debugDescription)")
                }

                if let pure = assistantTurns.last(where: { !hasToolUse($0) }) {
                    let t = textFromTurn(pure)
                    if !t.isEmpty {
                        logger.info("[BackgroundNotification] source=pure-text-turn(agentHistory) first20=\(String(t.prefix(20)).debugDescription)")
                        return String(t.prefix(200))
                    }
                }
                if let any = assistantTurns.last(where: { !textFromTurn($0).isEmpty }) {
                    let t = textFromTurn(any)
                    logger.info("[BackgroundNotification] source=any-text-turn(agentHistory) first20=\(String(t.prefix(20)).debugDescription)")
                    return String(t.prefix(200))
                }
                logger.info("[BackgroundNotification] source=fallback")
                return "Task completed."
            }()
            logger.info("[BackgroundNotification] responseSummary ready length=\(responseSummary.count) first20=\(String(responseSummary.prefix(20)).debugDescription) wasBackground=\(wasBackground)")
            let fallbackTitle = messages.first(where: { $0.role == .user })?.content.prefix(60).description ?? "Agent task"
            let bgTaskID = backgroundTaskID
            backgroundTaskID = .invalid
            let otherActive = SessionActivityTracker.shared.activeSessions
                .filter { $0 != sid }
            logger.info("[BKA][BGTask] otherActive=\(otherActive.count) ids=[\(otherActive.map { $0.prefix(8) }.joined(separator: ","))] before Task")
            Task {
                if otherActive.isEmpty {
                    await AgentLiveActivityManager.shared.finishActivity(
                        lastMessages: sid.isEmpty ? [:] : [sid: responseSummary]
                    )
                } else {
                    AgentLiveActivityManager.shared.markSessionCompleted(
                        sessionId: sid,
                        lastMessage: responseSummary
                    )
                }
                let sessionTitle: String
                if let session = await ChatStore.shared.getSession(sid),
                   let t = session.title, !t.isEmpty {
                    sessionTitle = t
                } else {
                    sessionTitle = fallbackTitle
                }
                BackgroundKeepAliveManager.shared.postBackgroundTaskNotification(
                    sessionTitle: sessionTitle, responseSummary: responseSummary, sessionId: sid, isError: hasError, wasBackground: wasBackground
                )
                await MainActor.run {
                    if bgTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskID)
                    }
                }
            }
        }
    }

    // MARK: - Background Status Timer

    /// Starts a periodic timer that logs tool execution status while backgrounded.
    /// Only emits logs when the app is actually in the background.
    func startBackgroundStatusTimer() {
        stopBackgroundStatusTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            // Only log when actually in background
            guard UIApplication.shared.applicationState != .active else { return }
            let remaining = UIApplication.shared.backgroundTimeRemaining
            guard remaining < 99999 else {
                // Background task ended — stop timer
                timer.invalidate()
                self.backgroundStatusTimer = nil
                return
            }
            let remainingStr = String(format: "%.1fs", remaining)
            let status = self.backgroundToolStatusSummary()
            // Escalate to WARN once we're inside the last 15s — past this
            // point iOS is liable to suspend the process at any moment, so
            // any subsequent log noise is ranked accordingly. Below 60s
            // we keep the existing 5s cadence; we don't need finer
            // granularity until we're closer to expiry.
            if remaining < 15 {
                logger.warning("[Background] ⏱ remaining: \(remainingStr) (CRITICAL <15s) | \(status)")
            } else {
                logger.info("[Background] ⏱ remaining: \(remainingStr) | \(status)")
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        backgroundStatusTimer = timer
    }

    func stopBackgroundStatusTimer() {
        backgroundStatusTimer?.invalidate()
        backgroundStatusTimer = nil
    }

    /// Builds a one-line summary of current tool execution state for background logging.
    func backgroundToolStatusSummary() -> String {
        // Find the active assistant message (last one being processed)
        guard let assistantMsg = messages.last, assistantMsg.role == .assistant else {
            return "no active tool"
        }

        // Find the most recent tool block
        guard let toolBlock = assistantMsg.blocks.last(where: { $0.kind != .text }) else {
            return "streaming text (\(assistantMsg.blocks.last?.content.count ?? 0) chars)"
        }

        let toolName: String
        switch toolBlock.kind {
        case .text: toolName = "text"
        case .thinking: toolName = "thinking"
        case .shellTool: toolName = "shell"
        case .fileReadTool: toolName = "file_read"
        case .fileWriteTool: toolName = "file_write"
        case .fileEditTool: toolName = "file_edit"
        case .browserTool: toolName = "browser"
        case .readImageTool: toolName = "read_image"
        case .memoryTool: toolName = "memory"
        case .info: toolName = "info"
        }

        let desc = toolBlock.toolDescription
        let elapsed: String
        if let start = toolBlock.toolStartTime {
            elapsed = String(format: "%.1fs", Date().timeIntervalSince(start))
        } else {
            elapsed = "?"
        }

        let statusStr: String
        switch toolBlock.toolStatus {
        case .streaming(let bytes):
            statusStr = "streaming(\(bytes)B)"
        case .running:
            statusStr = "running"
        case .success:
            statusStr = "success"
        case .failed(let msg):
            statusStr = "failed(\(msg.prefix(50)))"
        case .cancelled:
            statusStr = "cancelled"
        case .none:
            statusStr = "pending"
        }

        let outputPreview: String
        if !toolBlock.content.isEmpty {
            let trimmed = toolBlock.content.suffix(80).replacingOccurrences(of: "\n", with: "↵")
            outputPreview = " output=\"...\(trimmed)\""
        } else {
            outputPreview = ""
        }

        // Browser-specific info
        var browserInfo = ""
        if case .browserTool = toolBlock.kind {
            if let bm = browserTabPool.activeManager {
                let url = bm.currentURL
                if !url.isEmpty {
                    browserInfo = " url=\(url.prefix(60))"
                }
                if bm.isLoading {
                    browserInfo += " loading=true"
                }
            }
        }

        // Running command PID info
        var pidInfo = ""
        if !runningCommandPids.isEmpty {
            let pidList = runningCommandPids.sorted().map(String.init).joined(separator: ",")
            pidInfo = " pids=[\(pidList)]"
        }

        let summary = "tool=\(toolName) status=\(statusStr) elapsed=\(elapsed)\(pidInfo) desc=\"\(desc.prefix(40))\"\(outputPreview)\(browserInfo)"
        SessionActivityTracker.shared.currentToolStatus = "\(toolName): \(statusStr)"
        if let sid = self.sessionId {
            SessionActivityTracker.shared.updateToolInfo(sessionId: sid, toolName: toolName, toolStatus: statusStr)
        }
        return summary
    }

    /// Called from the agent loop after a tool result is collected.
    /// If the background task was expired, this suspends the loop until
    /// the app returns to the foreground, then re-registers a background task
    /// so the next iteration can proceed.
    func waitIfBackgroundSuspended() async {
        // Skip suspension only while a long-lived execution leg is actually
        // alive. A configured toggle cannot rescue a stopped audio engine.
        if BackgroundKeepAliveManager.shared.hasRuntimeBackgroundSurvivalLeg { return }
        guard backgroundSuspended else { return }

        // If the app is already in the foreground (user returned before we got here),
        // just clear the flag, re-register background task, and continue.
        if UIApplication.shared.applicationState == .active {
            logger.info("[Background] App already active — resuming immediately")
            backgroundSuspended = false
            beginBackgroundProcessing(resumingAfterExpiration: true)
            return
        }

        logger.info("[Background] Agent loop suspended — waiting for foreground")

        // Listen for foreground notification to resume
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.foregroundContinuation = continuation
            self.foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                logger.info("[Background] Foreground notification — resuming agent loop")
                self.backgroundSuspended = false
                // Re-register a background task for the continued work
                self.beginBackgroundProcessing(resumingAfterExpiration: true)
                if let c = self.foregroundContinuation {
                    self.foregroundContinuation = nil
                    c.resume()
                }
                if let obs = self.foregroundObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.foregroundObserver = nil
                }
            }
        }
    }

    /// Pauses the agent loop when the user activates browser takeover.
    /// The loop suspends here until the user dismisses the browser sheet.
    func waitIfBrowserTakeover() async {
        guard browserTakeoverActive else { return }
        logger.info("[Takeover] Agent loop pausing for browser takeover")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.takeoverContinuation = continuation
        }
        logger.info("[Takeover] Agent loop resumed from browser takeover")

        // Take a screenshot so the agent sees what the user did during takeover
        let screenshotInput = BrowserActionInput(
            action: .screenshot, url: nil, selector: nil, text: nil,
            coordinateX: nil, coordinateY: nil, direction: nil, amount: nil,
            script: nil, userAgent: nil, maxDepth: nil, tabId: nil
        )
        if let result = try? await browserTabPool.execute(action: screenshotInput),
           let b64 = result.base64Image,
           let data = Data(base64Encoded: b64) {
            // Persist the takeover screenshot the same way browser_use
            // does so request-level budget elision can point the model
            // back at it via read_image.
            let timestamp = Int(Date().timeIntervalSince1970)
            let screenshotFilename = "takeover_\(timestamp).jpg"
            let sid = sessionId ?? "unknown"
            let persistDir = Self.minisBrowserPersistentDir(for: sid)
            try? FileManager.default.createDirectory(at: persistDir, withIntermediateDirectories: true)
            let persistPath = persistDir.appendingPathComponent(screenshotFilename)
            try? data.write(to: persistPath)
            let linuxPath = "\(Self.minisBrowserLinuxDir)/\(screenshotFilename)"

            // Inject a user message with the takeover screenshot so the model sees the current state
            let takeoverNote = "[Browser takeover] The user manually operated the browser. Here is a screenshot of the current browser state after their interaction."
            let msg = AgentMessage(role: .user, parts: [
                .text(takeoverNote),
                .imageData(data: data, mimeType: "image/jpeg", linuxPath: linuxPath)
            ])
            agentHistory.append(msg)
        }
    }

    /// Waits for the user to finish a mid-action browser takeover.
    /// Called after `browserTabPool.execute(action:)` when `browserTakeoverActive` is true.
    /// Returns a fresh screenshot result after the user finishes, or nil on timeout.
    func waitForMidActionTakeover() async -> BrowserActionResult? {
        logger.info("[Takeover] Mid-action: pausing browser action for user takeover")

        // Start 5-minute timeout
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                logger.info("[Takeover] Mid-action takeover timed out after 5 minutes")
                self.browserTakeoverActive = false
                if let c = self.midActionTakeoverContinuation {
                    self.midActionTakeoverContinuation = nil
                    c.resume()
                }
            }
        }
        self.takeoverTimeoutTask = timeoutTask

        // Suspend until the user finishes or timeout fires
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.midActionTakeoverContinuation = continuation
        }

        // Clean up timeout — if cancel() is a no-op, the timeout already fired
        let timedOut = timeoutTask.isCancelled == false
        timeoutTask.cancel()
        self.takeoverTimeoutTask = nil

        logger.info("[Takeover] Mid-action: resumed (timedOut=\(timedOut))")

        // Take a fresh screenshot so the agent sees the user's changes
        let screenshotInput = BrowserActionInput(
            action: .screenshot, url: nil, selector: nil, text: nil,
            coordinateX: nil, coordinateY: nil, direction: nil, amount: nil,
            script: nil, userAgent: nil, maxDepth: nil, tabId: nil
        )
        if let result = try? await browserTabPool.execute(action: screenshotInput) {
            return result
        }
        return nil
    }

    /// Called when the user dismisses the browser takeover sheet.
    func resumeFromBrowserTakeover() {
        browserTakeoverActive = false
        // Cancel mid-action timeout
        takeoverTimeoutTask?.cancel()
        takeoverTimeoutTask = nil
        // Resume mid-action continuation if active
        if let c = midActionTakeoverContinuation {
            midActionTakeoverContinuation = nil
            c.resume()
        }
        // Resume between-turn continuation if active
        if let c = takeoverContinuation {
            takeoverContinuation = nil
            c.resume()
        }
    }

    func stopCurrentCommand() {
        // A tool can be in several cancellable states:
        //   - one or more live iSH processes (runningCommandPids non-empty),
        //   - a pre-execution delay countdown (toolDelayWaitActive),
        //   - an in-flight browser_use load (a tab is mid-navigation).
        // Any of these is a valid stop target. [T-ios-browser-tool-stop-button]
        // Browser tools don't go through iSH, so without the hasLoadingTab arm
        // the per-bubble stop button was a NOOP for a hung `navigate` — it bailed
        // here because runningCommandPids was empty. Bail only when NONE apply,
        // so random taps don't poison the flag for a future real invocation.
        let browserLoading = browserTabPool.hasLoadingTab
        guard !runningCommandPids.isEmpty || toolDelayWaitActive || browserLoading else { return }
        commandCancelledByUser = true
        // Stop any in-flight browser page loads. stopLoading() resolves the
        // manager's navigationContinuation, so the awaited browserTabPool
        // .execute(action:) returns and the hung tool call completes.
        if browserLoading {
            let n = browserTabPool.stopAllLoading()
            logger.info("⏹️ stopCurrentCommand — stopped \(n) loading browser tab(s)")
        }
        // Stop ALL currently running shells — concurrent tool execution
        // can have many in flight at once and a stop tap should cancel
        // the entire batch. [T-concurrent-tools 2026-05-25]
        if !runningCommandPids.isEmpty {
            // Coordinator's stopCurrentCommand() is already "kill every
            // in-flight pid across every session", which matches what we
            // want for concurrent tool execution: one stop tap = cancel
            // every shell currently running.
            Task { await ISHExecutionCoordinator.shared.stopCurrentCommand() }
        }
        runningCommandPids.removeAll()
        commandStartTime = nil
    }

    func clearChat() {
        messages.removeAll()
        agentHistory.removeAll()
        toolSnapshots.removeAll()
        errorMessage = nil
        cachedLatestMarker = nil
        toolLoopDetector.reset()

        if let sessionId {
            Task { await ISHExecutionCoordinator.shared.sessionDidTerminate(sessionId: sessionId) }
            BrowserTabPool.deletePersistedData(for: sessionId)
            BrowserUseOffloadBridge.releasePool(forSession: sessionId)
            Task {
                await ChatStore.shared.deleteMessages(sessionId: sessionId)
                await ChatStore.shared.deleteCompactMarkers(sessionId: sessionId)
            }
        }
    }

}
