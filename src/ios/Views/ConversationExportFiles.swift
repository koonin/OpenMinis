import Foundation

/// One instance per export, used on its serial export task. Copies referenced
/// files, never scans another session or downloads remote links.
final class ConversationExportFiles {
    struct Attachment: Codable {
        let source: String
        let path: String?
        let warning: String?
    }

    let directory: URL
    private(set) var attachments: [Attachment] = []
    private var copied: [String: String] = [:]
    var warningCount: Int { attachments.filter { $0.warning != nil }.count }
    var fileCount: Int { copied.count }

    init(directory: URL) { self.directory = directory }

    static func createArchive(from directory: URL, to archive: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { zippedURL in
            do {
                try FileManager.default.copyItem(at: zippedURL, to: archive)
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard isReadableFile(archive) else { throw CocoaError(.fileNoSuchFile) }
    }

    static func isReadableFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true && FileManager.default.isReadableFile(atPath: url.path)
    }

    /// Validate after resolving symlinks: a link or ../ cannot export unrelated
    /// app data. Names in the archive are generated, not user-controlled paths.
    func copy(_ source: URL, allowedRoots: [URL], label: String) -> Attachment {
        let canonical = source.standardizedFileURL.resolvingSymlinksInPath()
        let allowed = allowedRoots.contains {
            canonical.path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/")
        }
        guard allowed, Self.isReadableFile(canonical) else {
            return recordMissing(label, reason: "File missing, unreadable, or outside this session's export scope")
        }
        if let path = copied[canonical.path] {
            return Attachment(source: label, path: path, warning: nil)
        }
        let ext = canonical.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let name = String(format: "%05d", copied.count + 1) + (ext.isEmpty ? "" : "." + String(ext.prefix(12)))
        let relative = "attachments/" + name
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("attachments"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: canonical, to: directory.appendingPathComponent(relative))
            copied[canonical.path] = relative
            let item = Attachment(source: label, path: relative, warning: nil)
            attachments.append(item)
            return item
        } catch {
            return recordMissing(label, reason: "Could not copy attachment: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func recordMissing(_ label: String, reason: String) -> Attachment {
        let item = Attachment(source: label, path: nil, warning: reason)
        attachments.append(item)
        return item
    }

    /// Inline Markdown image/file links and user attachment XML use session-
    /// scoped minis:// or Linux paths. Keep remote references as links and report
    /// that they are not offline; never make network requests during export.
    func rewriteReferences(in text: String, sessionRoot: URL, sharedRoot: URL) -> String {
        let pattern = #"!?\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))(?:\s+[^)\n]*)?\)|<file\s+path="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let index = (1...3).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
            let range = match.range(at: index)
            let raw = ns.substring(with: range)
            let isImage = ns.substring(with: match.range).hasPrefix("![")
            if raw.hasPrefix("https://") || raw.hasPrefix("http://") || raw.hasPrefix("data:") {
                if isImage { recordMissing(raw, reason: "Remote or inline image was left as a link; not bundled offline") }
                continue
            }
            guard let source = Self.resolve(raw, sessionRoot: sessionRoot, sharedRoot: sharedRoot) else {
                if isImage { recordMissing(raw, reason: "Unsupported image path; not bundled") }
                continue
            }
            let item = copy(source, allowedRoots: [sessionRoot, sharedRoot], label: raw)
            if let path = item.path, let swiftRange = Range(range, in: result) {
                result.replaceSubrange(swiftRange, with: path)
            }
        }
        return result
    }

    static func resolve(_ raw: String, sessionRoot: URL, sharedRoot: URL) -> URL? {
        let decoded = raw.removingPercentEncoding ?? raw
        let path: String
        if decoded.hasPrefix("minis://") {
            path = String(decoded.dropFirst("minis://".count))
        } else if decoded.hasPrefix("/var/minis/") {
            path = String(decoded.dropFirst("/var/minis/".count))
        } else if decoded.hasPrefix("file://"), let url = URL(string: raw) {
            return url // copy() validates scope before reading.
        } else if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded) // same scope check
        } else if decoded.contains(":") || decoded.hasPrefix("#") {
            return nil
        } else {
            return sessionRoot.appendingPathComponent("workspace").appendingPathComponent(decoded)
        }
        // Also accept the canonical minis://var/minis/workspace/... form.
        let relative = path.hasPrefix("var/minis/") ? String(path.dropFirst("var/minis/".count)) : path
        if relative.hasPrefix("shared/") {
            return sharedRoot.appendingPathComponent(String(relative.dropFirst("shared/".count)))
        }
        guard ["workspace/", "attachments/", "images/", "browser/"].contains(where: { relative.hasPrefix($0) }) else { return nil }
        return sessionRoot.appendingPathComponent(relative)
    }

    func finish() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(attachments).write(to: directory.appendingPathComponent("attachments.json"))
        let notes = attachments.compactMap { item in item.warning.map { "- \(item.source): \($0)" } }
        let readme = """
        Conversation export / 对话导出

        Extract the entire ZIP before opening the transcript. Keep attachments/ beside it.
        请先完整解压 ZIP；聊天记录和 attachments 文件夹需放在同一目录。
        The TXT export also includes conversation.md for Markdown viewers that display images.
        TXT 导出另附 conversation.md，可用支持本地图片的 Markdown 阅读器打开。
        Copied files / 已打包文件: \(fileCount)
        Missing or unbundled references / 未打包引用: \(warningCount)
        See attachments.json for the file mapping. Remote links are not downloaded.
        文件对应关系见 attachments.json；远程链接不会自动下载。

        \(notes.joined(separator: "\n"))
        """
        try Data(readme.utf8).write(to: directory.appendingPathComponent("README.txt"))
    }
}
