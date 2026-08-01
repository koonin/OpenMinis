import Foundation

/// Shared contract for the iOS scheduled-task setup flow.
///
/// Shortcuts owns the clock trigger; Minis contributes the `Send Prompt`
/// action and an in-app guide. Keeping the routing rules and agent guidance in
/// this small Foundation-only type makes the most failure-prone parts of the
/// flow independently testable.
enum ScheduledTaskSetupGuide {
    static let setupDeepLink = "minis://settings/scheduled-tasks"
    static let shortcutsAppDeepLink = "shortcuts://"
    static let createShortcutDeepLink = "shortcuts://create-shortcut"
    static let maxPreparedPromptCharacters = 8_000

    struct PreparedPrompt: Equatable {
        let text: String
        let wasTruncated: Bool
    }

    /// Authoritative instructions injected into the agent system prompt.
    /// This intentionally uses a saved regular shortcut as the stable bridge
    /// to Personal Automation. The labels for creating an inline blank
    /// automation vary across iOS releases, while choosing a saved shortcut
    /// remains understandable and lets the user test the task independently.
    static let agentGuidance = """
    Scheduled tasks: crontab / at / nohup loops stop when the app is suspended, so they are not reliable iOS schedulers. For a recurring task that must fire beyond the current conversation, explain that iOS uses an Apple Shortcuts Personal Automation to trigger Minis. Minis cannot create, list, inspect, or edit the user's Personal Automations.
    If the user already supplied concrete task instructions, turn them into one concise, complete, self-contained prompt, percent-encode that prompt as a UTF-8 URL query value, replace the placeholder in `[Set Up Scheduled Tasks](minis://settings/scheduled-tasks?prompt=<encoded-prompt>)`, and never leave the angle-bracket placeholder in the actual link. Use `%20` for spaces; characters such as `&`, `#`, `?`, `%`, newlines, Chinese text, and emoji must be percent-encoded. Keep the encoded prompt well below the 8,000-character ingestion limit. If no concrete prompt was supplied, use `[Set Up Scheduled Tasks](minis://settings/scheduled-tasks)`.
    Give this exact two-stage manual path. First create a regular shortcut: Shortcuts tab → plus button (or the app's Create Shortcut button) → Add Action → Apps → Minis → Send Prompt（发送提示）→ tap the Prompt（提示）placeholder → paste the prepared prompt → leave Wait for Result off → give the shortcut a recognizable name → Done. Then add the schedule: Automation → plus button, Create Personal Automation, or New Automation—whichever appears → Time of Day → choose the schedule → choose Run Immediately（立即运行）when shown → Next → select or search for that saved shortcut by name. If the system opens an action editor instead of showing saved shortcuts, add Run Shortcut（运行快捷指令）and select the saved shortcut, then tap Next if shown. If the final screen instead shows Ask Before Running（运行前询问）, turn it off and confirm Don’t Ask（不询问）→ Done.
    For a custom scheduled prompt, use Send Prompt only inside the saved shortcut. Never tell the user to select Ask Minis（询问 Minis）, Quick Task, a suggested Minis App Shortcut, or to build a Text → Ask Minis chain. Do not claim a link can create or confirm the Personal Automation for them.
    Waiting or polling within the current turn is different; use the current-turn waiting mechanism for that, not a Personal Automation.
    """

    /// Decode and normalize the optional one-shot prompt carried by the setup
    /// deep link. The user still reviews and explicitly copies it; this never
    /// writes to the pasteboard or starts an automation on its own.
    static func preparedPrompt(from url: URL) -> PreparedPrompt? {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "prompt" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let raw, !raw.isEmpty else { return nil }
        let wasTruncated = raw.count > maxPreparedPromptCharacters
        return PreparedPrompt(
            text: String(raw.prefix(maxPreparedPromptCharacters)),
            wasTruncated: wasTruncated
        )
    }

    /// Custom-scheme query items may contain a user's full task prompt. Keep
    /// that content out of logs while retaining enough route information for
    /// diagnostics. Non-Minis URLs preserve the existing log behavior.
    static func logDescription(for url: URL) -> String {
        guard url.scheme?.lowercased() == "minis" else { return url.absoluteString }

        let host = url.host.map { "//\($0)" } ?? ""
        let redactedQuery = url.query == nil ? "" : "?<redacted>"
        let redactedFragment = url.fragment == nil ? "" : "#<redacted>"
        return "minis:\(host)\(url.path)\(redactedQuery)\(redactedFragment)"
    }
}
