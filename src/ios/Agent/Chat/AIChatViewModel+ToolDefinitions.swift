import Foundation

// MARK: - Tool Definitions (Canonical)

extension AIChatViewModel {

    static let delegatedWorkerSessionSource = "delegated_worker"

    /// Browser operations available to delegated workers. These actions only
    /// read or navigate content; interactions, scripts, cookie access, fetches,
    /// and browser-setting mutations stay reserved for the parent agent.
    static let delegatedWorkerBrowserActions: [BrowserAction] = [
        .navigate, .screenshot, .getText, .scroll, .getPageInfo,
        .findElements, .getReadable, .getBackbone, .listTabs,
        .scrollAndCollect, .waitForDomStable,
    ]

    static let delegatedWorkerToolNames: Set<String> = [
        "file_read", "browser_use", "read_image",
    ]

    /// Workers may inspect task artifacts, but not global memory, skills,
    /// credentials, the guest root filesystem, or other private app state.
    nonisolated static func normalizedDelegatedWorkerReadPath(_ rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("minis://") {
            path = "/var/minis/" + String(path.dropFirst("minis://".count))
        }
        // Decode twice at most so a double-encoded traversal cannot become
        // meaningful only after a later URL/filesystem layer decodes it.
        for _ in 0..<2 {
            guard let decoded = path.removingPercentEncoding, decoded != path else { break }
            path = decoded
        }
        let standardized = (path as NSString).standardizingPath
        let allowedRoots = [
            "/var/minis/workspace",
            "/var/minis/attachments",
            "/var/minis/offloads",
            "/var/minis/browser",
            "/var/minis/shared",
        ]
        guard allowedRoots.contains(where: { root in
            standardized == root || standardized.hasPrefix(root + "/")
        }) else { return nil }
        return standardized
    }

    nonisolated static func delegatedWorkerMayRead(path rawPath: String) -> Bool {
        normalizedDelegatedWorkerReadPath(rawPath) != nil
    }

    /// Browser navigation is network-only for workers. Local/resource/action
    /// schemes would bypass the file namespace policy (for example
    /// minis://memory/GLOBAL.md), while data:/javascript: can manufacture a
    /// privileged local document inside WebKit.
    nonisolated static func delegatedWorkerMayNavigate(to rawURL: String?) -> Bool {
        guard let rawURL,
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }

    var isDelegatedWorkerSession: Bool {
        sessionSource == Self.delegatedWorkerSessionSource
    }

    /// Apply the worker's text/readiness policy to a group before any initial
    /// route or provider fallback is chosen.
    func groupForCurrentSessionRouting(_ group: ModelGroup) -> ModelGroup {
        guard isDelegatedWorkerSession else { return group }
        let store = ProviderConfigStore.shared
        var filtered = group
        guard store.workerGroupId == group.id else {
            filtered.memberEntryIds = []
            return filtered
        }
        filtered.memberEntryIds = group.memberEntryIds.filter { entryId in
            guard let entry = store.entry(for: entryId),
                  !entry.isHidden,
                  entry.model.capabilities.supportedModalities.contains(.textOutput),
                  let instance = store.instance(for: entry.providerInstanceId) else {
                return false
            }
            return instance.isEnabled && instance.hasAnyCredential
        }
        return filtered
    }

    /// Resolves the explicitly configured worker group to a text-output entry.
    /// There is intentionally no fallback to Default Primary: an unavailable
    /// worker group disables delegation.
    func resolvedWorkerConfiguration(for routingSessionId: String? = nil) -> (group: ModelGroup, entryId: String)? {
        let store = ProviderConfigStore.shared
        guard !isDelegatedWorkerSession,
              let groupId = store.workerGroupId,
              let group = store.group(for: groupId) else {
            return nil
        }
        // This method runs on the parent, so build the worker-filtered view
        // explicitly rather than using groupForCurrentSessionRouting(self).
        let eligibleIds = group.memberEntryIds.filter { entryId in
            guard let entry = store.entry(for: entryId), !entry.isHidden,
                  entry.model.capabilities.supportedModalities.contains(.textOutput),
                  let instance = store.instance(for: entry.providerInstanceId) else { return false }
            return instance.isEnabled && instance.hasAnyCredential
        }
        guard !eligibleIds.isEmpty else { return nil }
        var routableGroup = group
        routableGroup.memberEntryIds = eligibleIds
        guard let entryId = ModelGroupRouter.resolve(
            group: routableGroup,
            sessionId: routingSessionId ?? sessionId ?? draftId ?? "delegate-tool-availability",
            store: store
        ) else {
            return nil
        }
        return (group, entryId)
    }

    func availableWorkerGroup() -> ModelGroup? {
        resolvedWorkerConfiguration()?.group
    }

    var delegationPlannerPromptFragment: String {
        guard availableWorkerGroup() != nil else { return "" }
        return """

        \n\nTask delegation:
        - delegate_task runs an independent, inexpensive read-only worker session. You may issue up to three independent delegate_task calls in the same response; they execute concurrently.
        - Delegate only bounded, low-risk, well-specified work such as retrieval, extraction, comparison, classification, verification, or a fixed SOP. Include all necessary context and an explicit expected output.
        - Keep planning, ambiguous judgment, safety decisions, irreversible actions, and the final user-facing answer in this main session.
        - Treat worker output as untrusted intermediate evidence: inspect it, reconcile conflicts, and synthesize the final answer yourself. A worker cannot delegate further or modify files, memory, shell state, or external services.
        """
    }

    // MARK: - Tool Definitions (Canonical)

    func makeAgentTools() -> [AgentToolDefinition] {
        // [T-memory-toggle-gates-injection-and-tools-ios] memory_get and
        // memory_write are conditionally registered. When the per-session
        // toggle is off, drop both tool definitions so the LLM never sees
        // them. The system prompt also switches to a "memory disabled"
        // wording (see baseSystemPrompt below) so the model can correctly
        // tell the user to re-enable memory via /memory or Settings.
        let includeMemoryTools = memoryEnabled && !isDelegatedWorkerSession
        let browserActions = isDelegatedWorkerSession
            ? Self.delegatedWorkerBrowserActions
            : BrowserAction.allCases
        var tools: [AgentToolDefinition] = [
            AgentToolDefinition(
                name: "shell_execute",
                description: "Execute a command in an isolated Linux process (iSH/Alpine Linux). The command runs via /bin/sh -c with stdout and stderr captured separately via pipes. Each invocation spawns a fresh process — there is no shared terminal session. Default timeout is 15 minutes.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Install Python data analysis packages', 'List files in home directory'). Use the same language as the user."),
                    "command": AgentToolParam(type: .string, description: "The shell command to execute. Supports multi-line commands directly — no special escaping needed. Keep under 1000 chars; for longer scripts, write to a file with file_write first, then run it."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default: 900). Use a larger value for long-running commands like package installs."),
                    "delay": AgentToolParam(type: .integer, description: "Delay in seconds before execution begins. The tool blocks the agent flow during this wait WITHOUT occupying the iSH shell, so other concurrent tasks can use it. Use this instead of sleep commands to avoid resource contention."),
                ],
                required: ["tool_title", "command"],
                propertyOrdering: ["tool_title", "command", "timeout", "delay"]
            ),
            AgentToolDefinition(
                name: "file_read",
                description: isDelegatedWorkerSession
                    ? "Read a task-relevant text file from an allowed Minis workspace, attachment, offload, browser, or shared path. Memory, skills, credentials, and other filesystem paths are blocked."
                    : "Read a file from the Linux filesystem. Faster than shell_execute for reading files — no shell overhead. Returns file content with metadata. Rejects binary files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Read Python script contents', 'Check system configuration file'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to read (e.g. /var/minis/workspace/data.csv)"),
                    "offset": AgentToolParam(type: .integer, description: "1-based line number to start reading from (default: 1). Ignored when direction is 'tail'."),
                    "lines": AgentToolParam(type: .integer, description: "Maximum number of lines to return (default: all lines up to max_length)"),
                    "max_length": AgentToolParam(type: .integer, description: "Maximum character length of returned content (default: 15000)"),
                    "direction": AgentToolParam(type: .string, description: "Read direction: 'head' (from start, default) or 'tail' (from end of file)"),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "offset", "lines", "direction", "max_length"]
            ),
            AgentToolDefinition(
                name: "file_write",
                description: "Write content to a file on the Linux filesystem. Faster than shell_execute for writing files. Creates the file if it doesn't exist. Use append mode to add to existing files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Create Python statistics script', 'Write configuration file'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to write (e.g. /root/test.txt)"),
                    "content": AgentToolParam(type: .string, description: "The text content to write to the file"),
                    "append": AgentToolParam(type: .boolean, description: "If true, append to existing file instead of overwriting (default: false)"),
                    "create_dirs": AgentToolParam(type: .boolean, description: "If true, create parent directories if they don't exist (default: false)"),
                ],
                required: ["tool_title", "path", "content"],
                propertyOrdering: ["tool_title", "path", "content", "append", "create_dirs"]
            ),
            AgentToolDefinition(
                name: "file_edit",
                description: "Make targeted edits to an existing file using exact string replacement. ALWAYS use file_read first to see the current file contents before editing. Prefer file_edit over file_write when modifying existing files — only the changed part needs to be specified. The old_string must match exactly one location in the file (including whitespace/indentation), unless replace_all is true.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Fix typo in Python script', 'Update config value'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to the file to edit (e.g. /root/script.py)"),
                    "old_string": AgentToolParam(type: .string, description: "The exact text to find in the file. Must match precisely including whitespace and indentation. Must be unique in the file unless replace_all is true."),
                    "new_string": AgentToolParam(type: .string, description: "The replacement text. Use empty string to delete old_string."),
                    "replace_all": AgentToolParam(type: .boolean, description: "If true, replace ALL occurrences of old_string (default: false)"),
                ],
                required: ["tool_title", "path", "old_string", "new_string"],
                propertyOrdering: ["tool_title", "path", "old_string", "new_string", "replace_all"]
            ),
            AgentToolDefinition(
                name: "browser_use",
                description: isDelegatedWorkerSession
                    ? "Read web content without interacting with the site. Allowed actions are navigation, screenshots, text/readable extraction, scrolling, page/element inspection, tab listing, and waiting for the DOM to settle. Click, type, scripts, cookies, downloads, and browser-setting changes are unavailable."
                    : "Control a web browser with up to 3 tabs. Do NOT use this tool for minis:// action URLs (open_terminal, views, settings) — those are app deep links, use Markdown links in chat instead. The browser supports both web URLs and minis:// resource URLs. Use minis:// URLs to preview session files (e.g. navigate to minis://workspace/index.html). Sub-resources (JS, CSS, images, fonts) referenced via minis:// absolute paths or relative paths within HTML pages resolve correctly. Use navigate to open URLs, screenshot to see the page (returns an image), click/type to interact with elements, get_text/get_readable to extract content, scroll to navigate long pages, scroll_and_collect to scroll through infinite-scroll/virtual-rendered pages (like Twitter/X timelines) and accumulate unique content items across scroll positions in a single call, find_elements to discover interactive elements, get_page_info for page metadata, get_backbone to get a structural overview of the page DOM as a simplified tree, fetch to download files/resources using the page's session (returns metadata and a minis:// URL), new_tab to open an additional tab, close_tab to close a tab, and list_tabs to see all open tabs. Use set_viewport with viewport_width + viewport_height to override the viewport for the current session (e.g. before screenshotting a 1920×1080 HTML composition that would otherwise be cropped to the phone viewport); pass reset=true to drop the session override and fall back to the global browser setting. Use get_cookies to retrieve cookies for the current page URL / current site root domain only (including HttpOnly cookies). get_cookies supports optional 'keyword' (filter by cookie name) and 'fuzzy' (true=contains match, false=exact match, default true). It returns only a summary and an offload env file path — raw cookie values are NOT included in the tool response. To reuse cookies in shell commands: `. /var/minis/offloads/env_cookies_xxx.sh && command`. You may define alias variables when needed. Use set_cookies to write cookies into the current page's cookie store via the native cookie store (so even HttpOnly cookies, which JS cannot set, land). Pass a 'cookies' array of objects, each with name + value (required) and optional domain (defaults to the current page host), path (defaults to '/'), secure, http_only, and expires (Unix timestamp in seconds; omit for a session cookie). Use wait_for_dom_stable to wait until the page DOM stops changing (useful after navigation or interactions that trigger async data loading — polls every 0.5s, resolves when mutation rate gradient is stable for 3+ intervals, default timeout 10s). Use tab_id to target a specific tab (defaults to the most recently used tab).",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Open Wikipedia homepage', 'Take screenshot of current page'). Use the same language as the user."),
                    "action": AgentToolParam(type: .string, description: "The browser action to perform", enumValues: browserActions.map(\.rawValue)),
                    "url": AgentToolParam(type: .string, description: "URL to navigate to (for navigate action) or resource to download (for fetch action)"),
                    "selector": AgentToolParam(type: .string, description: "CSS selector for targeting elements (click, type, get_text, scroll, hover, find_elements). For scroll: specify a scrollable container to scroll (e.g. 'div.timeline'); if omitted, auto-detects the best scrollable element."),
                    "text": AgentToolParam(type: .string, description: "Text to type (for type action)"),
                    "coordinate_x": AgentToolParam(type: .integer, description: "X coordinate for click (alternative to selector)"),
                    "coordinate_y": AgentToolParam(type: .integer, description: "Y coordinate for click (alternative to selector)"),
                    "direction": AgentToolParam(type: .string, description: "Scroll direction", enumValues: ["up", "down"]),
                    "amount": AgentToolParam(type: .integer, description: "Scroll amount in pixels (default: 500)"),
                    "script": AgentToolParam(type: .string, description: "JavaScript code to execute (for execute_js action). The script runs inside an async function wrapper — `await` and top-level `return` are both supported (e.g. `var r = await fetch(url); return await r.json()`)."),
                    "user_agent": AgentToolParam(type: .string, description: "User agent profile to switch to", enumValues: ["desktop_safari", "mobile_safari"]),
                    "max_depth": AgentToolParam(type: .integer, description: "Maximum tree depth for get_backbone (default: 5)"),
                    "scroll_count": AgentToolParam(type: .integer, description: "Number of scroll steps for scroll_and_collect (default: 10, max: 20). Each step scrolls by 'amount' pixels and waits for new content."),
                    "item_selector": AgentToolParam(type: .string, description: "CSS selector for individual content items in scroll_and_collect (e.g. 'article', '[data-testid=\"tweet\"]'). If omitted, auto-detects repeated elements."),
                    "tab_id": AgentToolParam(type: .integer, description: "Target tab ID (optional, defaults to most recently used tab). Use list_tabs to see available tabs."),
                    "keywords": AgentToolParam(type: .string, description: "Filter cookies by name (for get_cookies). A space-separated string or array of strings. With fuzzy=true (default), ALL keywords must appear in the cookie name (case-insensitive). With fuzzy=false, cookie name must exactly equal any one of the provided keywords (case-insensitive). Omit to return all cookies for the current site."),
                    "fuzzy": AgentToolParam(type: .boolean, description: "Whether keyword matching is fuzzy (contains-all) or exact-any (for get_cookies, default: true)."),
                    "cookies": AgentToolParam(type: .string, description: "For set_cookies: a JSON array of cookie objects to write. Pass it as a JSON array (a JSON-encoded string of the array is also accepted). Each object: {\"name\": str (required), \"value\": str (required), \"domain\": str (optional, defaults to current page host), \"path\": str (optional, defaults to \"/\"), \"secure\": bool (optional), \"http_only\": bool (optional — sets an HttpOnly cookie that JS cannot read/set), \"expires\": int (optional, Unix timestamp in seconds; omit for a session cookie)}. Field-name variants from common cookie exports are accepted: httpOnly (=http_only), expirationDate (=expires), sameSite, and case/camel variants — so you can paste cookies verbatim from browser extensions (EditThisCookie / Cookie-Editor) or Playwright/Puppeteer storage."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds for wait_for_dom_stable (default: 10). The action polls every 0.5s and resolves when DOM mutation rate stabilizes."),
                    "viewport_width": AgentToolParam(type: .integer, description: "Viewport width in CSS pixels for set_viewport (e.g. 1920). Required together with viewport_height unless reset=true."),
                    "viewport_height": AgentToolParam(type: .integer, description: "Viewport height in CSS pixels for set_viewport (e.g. 1080). Required together with viewport_width unless reset=true."),
                    "reset": AgentToolParam(type: .boolean, description: "For set_viewport: when true, clear the session-level viewport override and fall back to the global browser setting."),
                    "full_page": AgentToolParam(type: .boolean, description: "For screenshot: capture the entire scrollable page by temporarily resizing the WebView to document.documentElement.scrollHeight. Default false captures viewport only. Capped at 32768px tall; when capped, result text includes 'Truncated: true' and the original height."),
                ],
                required: ["tool_title", "action"],
                propertyOrdering: ["tool_title", "action", "tab_id", "url", "selector", "text", "coordinate_x", "coordinate_y", "direction", "amount", "scroll_count", "item_selector", "script", "user_agent", "max_depth", "keywords", "fuzzy", "cookies", "timeout", "viewport_width", "viewport_height", "reset", "full_page"]
            ),
        ]

        if includeMemoryTools {
            tools.append(AgentToolDefinition(
                name: "memory_write",
                description: "Write a memory entry to today's daily log (YYYY-MM-DD.md). Memories persist across all sessions. Each entry is prepended with a timestamp. Save: user preferences, recurring patterns, key facts, project conventions, reusable knowledge. Avoid saving passwords, API keys, tokens, or secrets unless the user explicitly confirms after being warned. Keep entries concise and general-purpose. GLOBAL.md is read-only (user-maintained via Settings).",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Save user preference for Python', 'Note today's project context'). Use the same language as the user."),
                    "content": AgentToolParam(type: .string, description: "The memory content to write. Use concise Markdown with a short heading (## Topic) and context about what was done/learned."),
                ],
                required: ["tool_title", "content"],
                propertyOrdering: ["tool_title", "content"]
            ))
            tools.append(AgentToolDefinition(
                name: "memory_get",
                description: "Retrieve memories from persistent storage. Supports keyword-based fuzzy search across memory files. Returns matching lines with surrounding context. Use this to recall previous knowledge, user preferences, or past notes.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Recall user preferences', 'Search past notes'). Use the same language as the user."),
                    "scope": AgentToolParam(type: .string, description: "Memory scope to search: 'daily' for daily logs only, 'all' for daily logs + GLOBAL.md.", enumValues: ["daily", "all"]),
                    "keywords": AgentToolParam(type: .string, description: "Space-separated keywords for fuzzy matching (e.g. 'python preference' or 'API key setup'). All keywords must appear in a line or its surrounding context for a match. Leave empty to return full memory files."),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title", "scope", "keywords"]
            ))
        }

        // Only include read_image when the model supports image input
        if selectedModel.capabilities.supportedModalities.contains(.imageInput) {
            tools.append(AgentToolDefinition(
                name: "read_image",
                description: "Read an image file from the Linux filesystem and return it for visual analysis. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, or any visual output. The image is returned directly for your analysis along with metadata (dimensions, file size).",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'View generated bar chart', 'Inspect downloaded screenshot'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Linux path (e.g. /var/minis/attachments/chart.png) or minis:// URL (e.g. minis://attachments/chart.png)"),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path"]
            ))
        }

        if isDelegatedWorkerSession {
            return tools.filter { Self.delegatedWorkerToolNames.contains($0.name) }
        }

        if availableWorkerGroup() != nil {
            tools.append(AgentToolDefinition(
                name: "delegate_task",
                description: "Delegate one bounded, low-risk, read-only task to an independent worker agent from the configured Worker Group. Multiple calls in one response run concurrently (maximum three). The worker cannot delegate further or use shell/file/memory writes. You remain responsible for evaluating its output and answering the user.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user. Use the same language as the user."),
                    "task": AgentToolParam(type: .string, description: "A complete, self-contained task for the worker, including relevant facts, constraints, and acceptance criteria."),
                    "expected_output": AgentToolParam(type: .string, description: "Optional output format or evidence the worker should return."),
                    "timeout_seconds": AgentToolParam(type: .integer, description: "Optional end-to-end timeout in seconds, including queue and setup. Defaults to 180; clamped to 10-900."),
                ],
                required: ["tool_title", "task"],
                propertyOrdering: ["tool_title", "task", "expected_output", "timeout_seconds"]
            ))
        }

        return tools
    }

}
