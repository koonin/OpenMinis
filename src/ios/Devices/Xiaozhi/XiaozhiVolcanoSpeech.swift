import Foundation

/// Bounded NDJSON from Volcano's PCM HTTP stream. Only an explicit success
/// marker completes synthesis; EOF/error after some audio is still a failure.
struct XiaozhiVolcanoFrames {
    private var line = Data()
    private var wireBytes = 0
    private var pcmBytes = 0
    private var frames = 0
    private(set) var completed = false

    mutating func append(_ byte: UInt8) throws -> Data? {
        guard !completed, wireBytes < 8 * 1024 * 1024 else {
            throw XiaozhiError.message("火山语音流已结束或响应过大")
        }
        wireBytes += 1
        if byte == 10 { return try consumeLine() }
        guard line.count < 1024 * 1024 else { throw XiaozhiError.message("火山语音分段过大") }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> Data? {
        let last = line.isEmpty ? nil : try consumeLine()
        guard completed, pcmBytes > 0, pcmBytes % 2 == 0 else {
            throw XiaozhiError.message("火山语音未完整返回，原回复已保留；本轮没有重发")
        }
        return last
    }

    private mutating func consumeLine() throws -> Data? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.allSatisfy({ [9, 13, 32].contains($0) }) { return nil }
        frames += 1
        guard frames <= 4096,
              let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let code = frame["code"] as? Int else {
            throw XiaozhiError.message("火山语音响应格式错误")
        }
        if code == 20000000 {
            guard frame["data"] == nil || frame["data"] is NSNull else {
                throw XiaozhiError.message("火山语音结束格式错误")
            }
            completed = true
            return nil
        }
        guard code == 0 else {
            if code == 45000000 {
                throw XiaozhiError.message("火山未授权此音色或资源，请检查语音服务开通、音色权限与额度")
            }
            throw XiaozhiError.message("火山语音服务返回错误（\(code)），请检查服务配置或稍后重试")
        }
        guard let raw = frame["data"], !(raw is NSNull) else { return nil } // Optional timing metadata.
        guard let base64 = raw as? String,
              let pcm = Data(base64Encoded: base64), !pcm.isEmpty,
              pcmBytes + pcm.count <= 90 * 16_000 * 2 else {
            throw XiaozhiError.message("火山音频分段无效或超过时长限制")
        }
        pcmBytes += pcm.count
        return pcm
    }
}

@MainActor
final class XiaozhiVolcanoSpeech {
    static let shared = XiaozhiVolcanoSpeech()
    private var work: Task<Void, Error>?
    private var session: URLSession?
    private let configuration: URLSessionConfiguration?

    init(configuration: URLSessionConfiguration? = nil) { self.configuration = configuration }

    func cancel() {
        work?.cancel()
        session?.invalidateAndCancel()
    }

    func stream(_ request: URLRequest, onPCM: @escaping (Data) async throws -> Void) async throws {
        guard work == nil else { throw XiaozhiError.message("火山正在生成上一段声音，请稍后再试") }
        guard request.url?.scheme == "https", request.url?.host == "openspeech.bytedance.com",
              request.url?.path == "/api/v3/tts/unidirectional" else {
            throw XiaozhiError.message("火山语音连接地址无效")
        }
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 75
        let session = URLSession(configuration: config, delegate: XiaozhiVolcanoNoRedirect(), delegateQueue: nil)
        self.session = session
        let work = Task {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw XiaozhiError.message("火山语音响应无效") }
            guard http.statusCode == 200 else {
                if [401, 403].contains(http.statusCode) {
                    throw XiaozhiError.message("火山语音鉴权失败，请检查 API Key 和语音服务权限")
                }
                throw XiaozhiError.message("火山语音请求失败（HTTP \(http.statusCode)）")
            }
            var frames = XiaozhiVolcanoFrames()
            for try await byte in bytes {
                try Task.checkCancellation()
                if let pcm = try frames.append(byte) { try await onPCM(pcm) }
                if frames.completed { break }
            }
            if let pcm = try frames.finish() { try await onPCM(pcm) }
            try Task.checkCancellation()
        }
        self.work = work
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 75_000_000_000) } catch { return }
            work.cancel(); session.invalidateAndCancel()
        }
        defer {
            deadline.cancel(); session.invalidateAndCancel()
            self.work = nil; self.session = nil
        }
        do {
            try await withTaskCancellationHandler { try await work.value } onCancel: {
                work.cancel(); session.invalidateAndCancel()
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as XiaozhiError { throw error }
        catch { throw XiaozhiError.message("火山语音连接中断或超时，原回复已保留；本轮没有重发") }
    }
}

private final class XiaozhiVolcanoNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
