import Foundation
import MetricKit
import UIKit
import os

private let logger = AppLogger(category: "CrashReporter")

final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    private let maxReports = 20

    private var crashReportsDir: URL {
        // Keep crash reports alongside running logs (LoggingManager.logDirectory)
        // so the unified Logs UI can list both from one directory.
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("Logs", isDirectory: true)
    }

    private var launchMarkerURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("launch_marker")
    }

    static var hangSnapshotURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("last_hang_snapshot.txt")
    }

    static var crashStackURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("last_crash_stack.txt")
    }

    private var launched = false
    private let currentRunID = UUID().uuidString

    // MARK: - Log Ring Buffer

    private var logRing: [String] = []
    private let logRingCapacity = 20
    private var logRingLock = os_unfair_lock()

    func appendLog(_ line: String) {
        os_unfair_lock_lock(&logRingLock)
        if logRing.count >= logRingCapacity {
            logRing.removeFirst()
        }
        logRing.append(line)
        os_unfair_lock_unlock(&logRingLock)
    }

    func logRingSnapshot() -> [String] {
        os_unfair_lock_lock(&logRingLock)
        let snapshot = logRing
        os_unfair_lock_unlock(&logRingLock)
        return snapshot
    }

    // MARK: - Last API Tracking

    private var lastAPILock = os_unfair_lock()
    private var _lastAPIProvider: String?
    private var _lastAPIModel: String?

    func setLastAPI(provider: String, model: String) {
        os_unfair_lock_lock(&lastAPILock)
        _lastAPIProvider = provider
        _lastAPIModel = model
        os_unfair_lock_unlock(&lastAPILock)
    }

    private func lastAPI() -> (provider: String?, model: String?) {
        os_unfair_lock_lock(&lastAPILock)
        let p = _lastAPIProvider
        let m = _lastAPIModel
        os_unfair_lock_unlock(&lastAPILock)
        return (p, m)
    }

    private override init() {
        super.init()
    }

    // MARK: - Public API

    func onAppLaunch() {
        guard !launched else { return }
        launched = true
        CrashSignalHandler.install()
        checkStaleMarker()
        try? FileManager.default.removeItem(at: Self.hangSnapshotURL)
        try? FileManager.default.removeItem(at: Self.crashStackURL)
        writeLaunchMarker()
        MXMetricManager.shared.add(self)
        logger.info("CrashReporter initialized, signal handlers + MetricKit subscriber registered")
    }

    func onWillTerminate() {
        removeLaunchMarker()
        try? FileManager.default.removeItem(at: Self.hangSnapshotURL)
        try? FileManager.default.removeItem(at: Self.crashStackURL)
        logger.info("Launch marker removed (normal termination)")
    }

    @MainActor
    func updateMarkerPhase(phase: String) {
        let url = launchMarkerURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let observedAt = df.string(from: Date())
        marker["lastPhase"] = phase
        marker["lastObservedAt"] = observedAt
        // Legacy alias retained so markers remain readable across app-version
        // rollbacks. New reports describe this as an observation time, never
        // as the time the process terminated.
        marker["lastPhaseAt"] = observedAt
        marker["memoryMB"] = currentMemoryMB()
        marker["processMemoryHeadroomMB"] = processMemoryHeadroomMB()
        marker["activeSessionCount"] = SessionActivityTracker.shared.activeSessions.count
        marker["runningShellCommand"] = ShellCommandRingBuffer.hasRunningCommand
        let keepAliveRequested = BackgroundKeepAliveManager.shared.isActive
        marker["bkaRequestedActive"] = keepAliveRequested
        // Legacy alias for older readers. This has always represented BKA's
        // logical request state, not a UIApplication background-task assertion.
        marker["bgTaskActive"] = keepAliveRequested
        marker["logLinesAtLastObservation"] = logRingSnapshot()

        let remaining = UIApplication.shared.backgroundTimeRemaining
        marker["bgTaskRemaining"] = remaining > 99999 ? -1 : remaining

        // [T-bg-keepalive-debounce] BackgroundKeepAlive snapshot — so a crash
        // report shows the exact audio keep-alive state at the last phase change.
        let bka = BackgroundKeepAliveManager.shared
        marker["bkaSilentAudioPlaying"] = bka.silentAudioIsPlaying
        marker["bkaAudioSessionActive"] = bka.audioSessionIsActive
        marker["bkaStopDebouncePending"] = bka.stopDebouncePending
        if let evt = bka.lastBKAEvent {
            let at = bka.lastBKAEventAt.map { df.string(from: $0) } ?? "?"
            marker["bkaLastEvent"] = "[\(at)] \(evt)"
        }
        if let lc = bka.lastLifecycle {
            let at = bka.lastLifecycleAt.map { df.string(from: $0) } ?? "?"
            marker["bkaLastLifecycle"] = "[\(at)] \(lc)"
        }
        if bka.lastAudioInterruption != "none" {
            let at = bka.lastAudioInterruptionAt.map { df.string(from: $0) } ?? "?"
            marker["bkaAudioInterruption"] = "\(bka.lastAudioInterruption)(\(at))"
        } else {
            marker["bkaAudioInterruption"] = "none"
        }

        let api = lastAPI()
        if let p = api.provider { marker["lastAPIProvider"] = p }
        if let m = api.model { marker["lastAPIModel"] = m }

        let shellSnap = ShellCommandRingBuffer.syncSnapshot
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        marker["shellCommands"] = shellSnap.map { entry -> [String: Any] in
            var d: [String: Any] = [
                "index": entry.index,
                "startedAt": timeFmt.string(from: entry.startedAt),
                "command": entry.command,
                "sessionId": entry.sessionId
            ]
            if let code = entry.exitCode { d["exitCode"] = code }
            if let dur = entry.duration { d["duration"] = dur }
            return d
        }

        let registry = BrowserTabPoolRegistry.shared
        marker["webViewTotalTabs"] = registry.totalLiveTabs()
        marker["webViewGlobalCap"] = BrowserTabPoolRegistry.globalTabCap
        let tabSnapshots = registry.allTabSnapshots()
        marker["webViewTabs"] = tabSnapshots.map { tab -> [String: Any] in
            [
                "sessionId": tab.sessionId,
                "tabId": tab.tabId,
                "url": tab.url,
                "title": tab.title,
                "isLoading": tab.isLoading,
                "inUse": tab.inUse,
                "lastActivityAgo": round(tab.lastActivityAgo * 10) / 10
            ]
        }

        if let updated = try? JSONSerialization.data(withJSONObject: marker),
           let json = String(data: updated, encoding: .utf8) {
            try? json.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Memory

    private func currentMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            return Int(info.phys_footprint / (1024 * 1024))
        }
        return 0
    }

    private func processMemoryHeadroomMB() -> Int {
        return Int(os_proc_available_memory() / (1024 * 1024))
    }

    // MARK: - Launch Marker

    private func writeLaunchMarker() {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let pid = ProcessInfo.processInfo.processIdentifier

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let now = df.string(from: Date())

        let marker: [String: Any] = [
            "schemaVersion": 2,
            "runID": currentRunID,
            "build": "\(version) (\(build))",
            "pid": pid,
            "launchedAt": now,
            "lastPhase": "active",
            "lastObservedAt": now,
            // Legacy alias; this is a lifecycle observation timestamp, not a
            // crash timestamp.
            "lastPhaseAt": now,
            "memoryMB": currentMemoryMB(),
            "processMemoryHeadroomMB": processMemoryHeadroomMB(),
            "logLinesAtLastObservation": logRingSnapshot()
        ]

        let url = launchMarkerURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: marker),
           let json = String(data: data, encoding: .utf8) {
            try? json.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func removeLaunchMarker() {
        try? FileManager.default.removeItem(at: launchMarkerURL)
    }

    private func checkStaleMarker() {
        let url = launchMarkerURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let detectedAt = Date()

        var markerInfo: [String: Any]?
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            markerInfo = json
        }

        let lastPhase = (markerInfo?["lastPhase"] as? String) ?? "unknown"
        let lastObservedAt = (markerInfo?["lastObservedAt"] as? String)
            ?? (markerInfo?["lastPhaseAt"] as? String)
        let memoryMB = markerInfo?["memoryMB"] as? Int
        // `memoryFreeMB` was the old, misleading name for the same
        // os_proc_available_memory() value. Read it only as a compatibility
        // fallback for markers written by older builds.
        let processMemoryHeadroomMB = (markerInfo?["processMemoryHeadroomMB"] as? Int)
            ?? (markerInfo?["memoryFreeMB"] as? Int)
        let markerBuild = markerInfo?["build"] as? String
        let previousRunID = markerInfo?["runID"] as? String
        let previousPID = markerInfo?["pid"] as? Int
        let previousLaunchedAt = markerInfo?["launchedAt"] as? String
        let runningShellValue = markerInfo?["runningShellCommand"] as? Bool
        let bkaRequestedActiveValue = (markerInfo?["bkaRequestedActive"] as? Bool)
            ?? (markerInfo?["bgTaskActive"] as? Bool)
        let runningShell = runningShellValue ?? false
        let bkaRequestedActive = bkaRequestedActiveValue ?? false
        let bgTaskRemaining = markerInfo?["bgTaskRemaining"] as? Double
        let activeSessionCount = markerInfo?["activeSessionCount"] as? Int
        let bkaSilentAudioPlaying = markerInfo?["bkaSilentAudioPlaying"] as? Bool
        let bkaAudioSessionActive = markerInfo?["bkaAudioSessionActive"] as? Bool
        let bkaStopDebouncePending = markerInfo?["bkaStopDebouncePending"] as? Bool
        let bkaLastEvent = markerInfo?["bkaLastEvent"] as? String
        let bkaLastLifecycle = markerInfo?["bkaLastLifecycle"] as? String
        let bkaAudioInterruption = markerInfo?["bkaAudioInterruption"] as? String
        let lastAPIProvider = markerInfo?["lastAPIProvider"] as? String
        let lastAPIModel = markerInfo?["lastAPIModel"] as? String
        let webViewTotalTabs = markerInfo?["webViewTotalTabs"] as? Int
        let webViewGlobalCap = markerInfo?["webViewGlobalCap"] as? Int
        let webViewTabs = markerInfo?["webViewTabs"] as? [[String: Any]]
        let savedLogLines = markerInfo?["logLinesAtLastObservation"] as? [String]
        let persistedCrashStack = try? String(contentsOf: Self.crashStackURL, encoding: .utf8)
        let persistedHangSnapshot = try? String(contentsOf: Self.hangSnapshotURL, encoding: .utf8)
        let hasCrashHandlerEvidence = !(persistedCrashStack?.isEmpty ?? true)
        let hasHangDetectorEvidence = !(persistedHangSnapshot?.isEmpty ?? true)

        // A stale marker proves only that the previous run did not execute its
        // cleanup hook. When every persisted background-work signal explicitly
        // says "idle", normal OS process reclamation is expected and should not
        // be surfaced to the user as a crash. Require every field so an older or
        // incomplete marker is never silently discarded.
        let explicitlyIdleBackground =
            lastPhase == "background"
            && activeSessionCount == 0
            && runningShellValue == false
            && bkaRequestedActiveValue == false
            && bkaSilentAudioPlaying == false
            && bkaAudioSessionActive == false
            && bkaStopDebouncePending == false
            && webViewTotalTabs == 0

        if explicitlyIdleBackground && !hasCrashHandlerEvidence && !hasHangDetectorEvidence {
            logger.info(
                "Stale launch marker ignored: previous run was explicitly idle in background; "
                + "no persisted crash or hang evidence"
            )
            return
        }

        let reportType: String
        if hasCrashHandlerEvidence {
            reportType = "Signal/Exception Crash (persisted crash-handler evidence)"
        } else if hasHangDetectorEvidence {
            reportType = "Unclassified Previous-Run Termination (persisted hang evidence; OS cause unknown)"
        } else {
            reportType = "Unclassified Previous-Run Termination (cause unknown — stale launch marker only)"
        }

        logger.warning(
            "Stale launch marker found: phase=\(lastPhase); "
            + "termination cause \(hasCrashHandlerEvidence ? "has crash-handler evidence" : "unknown")"
        )

        let savedShellCommands = (markerInfo?["shellCommands"] as? [[String: Any]]) ?? []

        writeReport(
            origin: .staleLaunchMarker,
            type: reportType,
            callStack: nil,
            savedShellCommands: savedShellCommands,
            savedLogLines: savedLogLines,
            detectedAt: detectedAt,
            previousRunID: previousRunID,
            previousPID: previousPID,
            previousLaunchedAt: previousLaunchedAt,
            lastPhase: lastPhase,
            lastObservedAt: lastObservedAt,
            memoryMB: memoryMB,
            processMemoryHeadroomMB: processMemoryHeadroomMB,
            activeSessionCount: activeSessionCount,
            runningShellCommand: runningShell,
            bkaRequestedActive: bkaRequestedActive,
            bgTaskRemaining: bgTaskRemaining,
            lastAPIProvider: lastAPIProvider,
            lastAPIModel: lastAPIModel,
            markerBuild: markerBuild,
            bkaSilentAudioPlaying: bkaSilentAudioPlaying,
            bkaAudioSessionActive: bkaAudioSessionActive,
            bkaStopDebouncePending: bkaStopDebouncePending,
            bkaLastEvent: bkaLastEvent,
            bkaLastLifecycle: bkaLastLifecycle,
            bkaAudioInterruption: bkaAudioInterruption,
            webViewTotalTabs: webViewTotalTabs,
            webViewGlobalCap: webViewGlobalCap,
            webViewTabs: webViewTabs
        )
    }

    // MARK: - MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let crashDiags = payload.crashDiagnostics, !crashDiags.isEmpty {
                for diag in crashDiags {
                    let exceptionType = diag.exceptionType?.description ?? "unknown"
                    let signal = diag.signal?.description ?? "unknown"
                    let type = "Exception: \(exceptionType) / Signal: \(signal)"

                    var stack: String?
                    let callStackTree = diag.callStackTree
                    let data = callStackTree.jsonRepresentation()
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let threads = json["callStacks"] as? [[String: Any]] {
                        var lines: [String] = []
                        for (ti, thread) in threads.enumerated() {
                            let crashed = (thread["threadAttributed"] as? Bool) ?? false
                            lines.append("Thread \(ti)\(crashed ? " (Crashed)" : ""):")
                            if let frames = thread["callStackRootFrames"] as? [[String: Any]] {
                                appendFrames(frames, to: &lines, depth: 0)
                            }
                        }
                        stack = lines.joined(separator: "\n")
                    }

                    let liveCommands = ShellCommandRingBuffer.syncSnapshot
                    let timeFmt = DateFormatter()
                    timeFmt.dateFormat = "HH:mm:ss"
                    let savedCmds: [[String: Any]] = liveCommands.map { entry in
                        var d: [String: Any] = [
                            "index": entry.index,
                            "startedAt": timeFmt.string(from: entry.startedAt),
                            "command": entry.command,
                            "sessionId": entry.sessionId
                        ]
                        if let code = entry.exitCode { d["exitCode"] = code }
                        if let dur = entry.duration { d["duration"] = dur }
                        return d
                    }
                    writeReport(type: type, callStack: stack, savedShellCommands: savedCmds)
                }
            }

            if let hangDiags = payload.hangDiagnostics, !hangDiags.isEmpty {
                for diag in hangDiags {
                    let durationMs = diag.hangDuration.converted(to: .milliseconds).value
                    let type = "Hang: \(String(format: "%.0f", durationMs))ms"
                    var stack: String?
                    let data = diag.callStackTree.jsonRepresentation()
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let threads = json["callStacks"] as? [[String: Any]] {
                        var lines: [String] = []
                        for (ti, thread) in threads.enumerated() {
                            let attributed = (thread["threadAttributed"] as? Bool) ?? false
                            lines.append("Thread \(ti)\(attributed ? " (Hung)" : ""):")
                            if let frames = thread["callStackRootFrames"] as? [[String: Any]] {
                                appendFrames(frames, to: &lines, depth: 0)
                            }
                        }
                        stack = lines.joined(separator: "\n")
                    }
                    writeReport(type: type, callStack: stack, savedShellCommands: [])
                    logger.warning("[MetricKit] Hang diagnostic: \(type)")
                }
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exitMetrics = payload.applicationExitMetrics else { continue }
            let fg = exitMetrics.foregroundExitData
            let bg = exitMetrics.backgroundExitData
            logger.info("[ExitMetrics] FG: normal=\(fg.cumulativeNormalAppExitCount) badAccess=\(fg.cumulativeBadAccessExitCount) watchdog=\(fg.cumulativeAppWatchdogExitCount) abnormal=\(fg.cumulativeAbnormalExitCount)")
            logger.info("[ExitMetrics] BG: normal=\(bg.cumulativeNormalAppExitCount) memLimit=\(bg.cumulativeMemoryResourceLimitExitCount) memPressure=\(bg.cumulativeMemoryPressureExitCount) watchdog=\(bg.cumulativeAppWatchdogExitCount) bgTimeout=\(bg.cumulativeBackgroundTaskAssertionTimeoutExitCount) cpu=\(bg.cumulativeCPUResourceLimitExitCount)")
        }
    }

    private func appendFrames(_ frames: [[String: Any]], to lines: inout [String], depth: Int) {
        for frame in frames {
            let binary = (frame["binaryName"] as? String) ?? "?"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? Int) ?? 0
            let address = (frame["address"] as? Int) ?? 0
            let indent = String(repeating: "  ", count: depth)
            lines.append("\(indent)\(binary) 0x\(String(address, radix: 16)) +\(offset)")
            if let subFrames = frame["subFrames"] as? [[String: Any]] {
                appendFrames(subFrames, to: &lines, depth: depth + 1)
            }
        }
    }

    // MARK: - Report Writing

    private enum ReportOrigin {
        case staleLaunchMarker
        case metricKit
    }

    private func writeReport(
        origin: ReportOrigin = .metricKit,
        type: String,
        callStack: String?,
        savedShellCommands: [[String: Any]] = [],
        savedLogLines: [String]? = nil,
        detectedAt: Date? = nil,
        previousRunID: String? = nil,
        previousPID: Int? = nil,
        previousLaunchedAt: String? = nil,
        lastPhase: String? = nil,
        lastObservedAt: String? = nil,
        memoryMB: Int? = nil,
        processMemoryHeadroomMB: Int? = nil,
        activeSessionCount: Int? = nil,
        runningShellCommand: Bool = false,
        bkaRequestedActive: Bool = false,
        bgTaskRemaining: Double? = nil,
        lastAPIProvider: String? = nil,
        lastAPIModel: String? = nil,
        markerBuild: String? = nil,
        bkaSilentAudioPlaying: Bool? = nil,
        bkaAudioSessionActive: Bool? = nil,
        bkaStopDebouncePending: Bool? = nil,
        bkaLastEvent: String? = nil,
        bkaLastLifecycle: String? = nil,
        bkaAudioInterruption: String? = nil,
        webViewTotalTabs: Int? = nil,
        webViewGlobalCap: Int? = nil,
        webViewTabs: [[String: Any]]? = nil
    ) {
        let fm = FileManager.default
        let dir = crashReportsDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // For stale-marker reports this is when the marker was detected, not
        // when the previous process ended. MetricKit does not provide an event
        // timestamp here either, so its reports use payload-receipt time.
        let reportDate = detectedAt ?? Date()
        let persistedCrashStack =
            (try? String(contentsOf: Self.crashStackURL, encoding: .utf8)) ?? ""
        let persistedHangSnapshot =
            (try? String(contentsOf: Self.hangSnapshotURL, encoding: .utf8)) ?? ""
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")

        // MetricKit may deliver multiple diagnostics together, and a stale
        // marker report can be generated in the same instant on launch. Keep
        // filenames time-sortable while guaranteeing that none overwrite.
        df.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let filename = "crash-\(df.string(from: reportDate))-\(UUID().uuidString.prefix(8)).log"

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let displayBuild = markerBuild ?? "\(version) (\(build))"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        var deviceModel = "unknown"
        var sysinfo = utsname()
        uname(&sysinfo)
        deviceModel = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let dateStr = df.string(from: reportDate)
        let dateMeaning: String
        switch origin {
        case .staleLaunchMarker:
            dateMeaning = "stale marker detected / report generated"
        case .metricKit:
            dateMeaning = "MetricKit payload received / report generated"
        }

        var report = """
        === Minis Crash Report ===
        Date:    \(dateStr) (\(dateMeaning))
        Type:    \(type)
        Build:   \(displayBuild)
        OS:      \(osVersion)
        Device:  \(deviceModel)
        Reporting Run ID: \(currentRunID)
        """

        if case .staleLaunchMarker = origin {
            if let runID = previousRunID {
                report += "\nPrevious Run ID:  \(runID)"
            } else {
                report += "\nPrevious Run ID:  unavailable (legacy marker)"
            }
            if let pid = previousPID {
                report += "\nPrevious PID:     \(pid)"
            }
            if let launchedAt = previousLaunchedAt {
                report += "\nPrevious Launch:  \(launchedAt)"
            }
            if let observedAt = lastObservedAt {
                report += "\nLast Observed:    \(observedAt) (saved lifecycle snapshot; not termination time)"
            } else {
                report += "\nLast Observed:    unavailable (termination time unknown)"
            }
            if !persistedCrashStack.isEmpty && !persistedHangSnapshot.isEmpty {
                report += "\nEvidence:         stale marker + persisted signal/exception stack + hang snapshot"
            } else if !persistedCrashStack.isEmpty {
                report += "\nEvidence:         stale launch marker + persisted signal/exception stack"
            } else if !persistedHangSnapshot.isEmpty {
                report += "\nEvidence:         stale launch marker + persisted HangDetector snapshot"
            } else {
                report += "\nEvidence:         stale launch marker only"
            }
            report += "\nOS Exit Reason:   unavailable"
        }

        if let phase = lastPhase {
            report += "\nLast Phase:       \(phase)"
        }

        if let mem = memoryMB {
            report += "\nMemory:           \(mem) MB (at last observation)"
        }

        // Memory State section
        if memoryMB != nil || processMemoryHeadroomMB != nil || activeSessionCount != nil {
            report += "\n\n--- Memory State (at last observation) ---"
            if let mem = memoryMB {
                report += "\nApp footprint:    \(mem) MB"
            }
            if let headroom = processMemoryHeadroomMB {
                report += "\nProcess memory headroom: \(headroom) MB"
            }
            if let sessions = activeSessionCount {
                report += "\nActive sessions:  \(sessions)"
            }
            report += "\nShell running:    \(runningShellCommand ? "yes" : "no")"
            report += "\nBackground keep-alive requested: \(bkaRequestedActive ? "yes" : "no")"
            if let rem = bgTaskRemaining {
                if rem < 0 {
                    report += "\nBG time remaining: unlimited"
                } else {
                    report += "\nBG time remaining: \(String(format: "%.1f", rem))s"
                }
            }
            // [T-bg-keepalive-debounce] BackgroundKeepAlive audio state at
            // the last persisted lifecycle observation.
            if let playing = bkaSilentAudioPlaying {
                report += "\nSilent audio playing: \(playing ? "yes" : "no")"
            }
            if let active = bkaAudioSessionActive {
                report += "\nAudio session active: \(active ? "yes" : "no")"
            }
            if let pending = bkaStopDebouncePending {
                report += "\nStop debounce pending: \(pending ? "yes" : "no")"
            }
            if let evt = bkaLastEvent {
                report += "\nLast BKA event:   \(evt)"
            }
            if let lc = bkaLastLifecycle {
                report += "\nLast lifecycle:   \(lc)"
            }
            if let interrupt = bkaAudioInterruption {
                report += "\nAudio interruption: \(interrupt)"
            }
            if let provider = lastAPIProvider, let model = lastAPIModel {
                report += "\nLast API:         \(provider) / \(model)"
            } else if let provider = lastAPIProvider {
                report += "\nLast API:         \(provider)"
            }
        }

        // WebView section
        report += "\n\n--- Active WebViews (at last observation) ---\n"
        if let total = webViewTotalTabs, let cap = webViewGlobalCap {
            report += "Total tabs: \(total) / \(cap) (global cap)\n"
        }
        if let tabs = webViewTabs, !tabs.isEmpty {
            report += "\n"
            for tab in tabs {
                let sid = (tab["sessionId"] as? String) ?? "?"
                let tabId = (tab["tabId"] as? Int) ?? 0
                let isLoading = (tab["isLoading"] as? Bool) ?? false
                let inUse = (tab["inUse"] as? Bool) ?? false
                let lastAgo = (tab["lastActivityAgo"] as? Double) ?? 0
                let rawUrl = (tab["url"] as? String) ?? ""
                let rawTitle = (tab["title"] as? String) ?? ""
                let url = rawUrl.isEmpty ? "(blank)" : String(rawUrl.prefix(80))
                let title = rawTitle.isEmpty ? "(untitled)" : rawTitle

                let statusIcon = isLoading ? "●" : (rawUrl.isEmpty ? "○" : "✓")
                let statusText = isLoading ? "loading" : (rawUrl.isEmpty ? "idle" : "loaded")
                var flags = ""
                if inUse { flags += " (in use)" }
                if lastAgo < 5 { flags += " (just active)" }

                report += "  [\(sid)] Tab \(tabId)  \(statusIcon) \(statusText)\(flags)  \(url)\n"
                report += "                               \(title)\n"
            }
        } else {
            report += "(no active WebViews)\n"
        }

        switch origin {
        case .staleLaunchMarker:
            report += "\n--- Shell Commands (saved at last observation) ---\n"
        case .metricKit:
            report += "\n--- Shell Commands (reporting process snapshot) ---\n"
        }

        if savedShellCommands.isEmpty {
            report += "(none recorded)\n"
        } else {
            for entry in savedShellCommands {
                let idx = (entry["index"] as? Int) ?? 0
                let num = String(format: "%2d", idx)
                let time = (entry["startedAt"] as? String) ?? "?"
                let command = (entry["command"] as? String) ?? "?"
                let status: String
                if let code = entry["exitCode"] as? Int, let dur = entry["duration"] as? Double {
                    status = String(format: "+%.1fs  exit=%d", dur, code)
                } else {
                    status = "RUNNING        "
                }
                report += "[\(num)] \(time)  \(status)  \(command)\n"
            }
        }

        switch origin {
        case .staleLaunchMarker:
            report += "\n--- Log Lines (saved at last observation) ---\n"
            if let savedLogLines {
                if savedLogLines.isEmpty {
                    report += "(none recorded)\n"
                } else {
                    for line in savedLogLines {
                        report += "\(line)\n"
                    }
                }
            } else {
                report += "(unavailable in legacy marker; current run's in-memory logs omitted)\n"
            }
        case .metricKit:
            let currentLogLines = logRingSnapshot()
            report += "\n--- Recent \(currentLogLines.count) Log Lines (reporting process) ---\n"
            if currentLogLines.isEmpty {
                report += "(none recorded)\n"
            } else {
                for line in currentLogLines {
                    report += "\(line)\n"
                }
            }
        }

        if !persistedHangSnapshot.isEmpty {
            report += "\n--- Persisted HangDetector Stacks ---\n"
            report += persistedHangSnapshot + "\n"
        }

        if !persistedCrashStack.isEmpty {
            report += "\n--- Signal/Exception Crash Stack ---\n"
            report += persistedCrashStack + "\n"
        }

        report += "\n--- MetricKit Call Stack ---\n"
        if let stack = callStack {
            report += stack + "\n"
        } else {
            switch origin {
            case .staleLaunchMarker:
                report += "(none delivered; a stale marker alone does not identify the termination cause)\n"
            case .metricKit:
                report += "(none available in the received diagnostic)\n"
            }
        }
        report += "\n=== End ===\n"

        let fileURL = dir.appendingPathComponent(filename)
        try? report.write(to: fileURL, atomically: true, encoding: .utf8)
        logger.info("Crash report written: \(filename)")

        pruneOldReports()
    }

    private func pruneOldReports() {
        let fm = FileManager.default
        let dir = crashReportsDir
        // Only prune crash reports (crash-*.log). Running logs (minis-*.log) now
        // share this directory and are pruned by LoggingManager, not here.
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])
            .filter({ $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("crash-") })
            .sorted(by: { ($0.lastPathComponent) < ($1.lastPathComponent) })
        else { return }

        if files.count > maxReports {
            for file in files.prefix(files.count - maxReports) {
                try? fm.removeItem(at: file)
                logger.info("Pruned old crash report: \(file.lastPathComponent)")
            }
        }
    }
}
