import Foundation

@main
struct XiaozhiVolcanoTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) } catch { checks += 1 }
        }
        func frame(_ data: Data) -> String { "{\"code\":0,\"data\":\"\(data.base64EncodedString())\"}\n" }
        let end = "{\"code\":20000000,\"data\":null}"
        var parser = XiaozhiVolcanoFrames(), received = Data()
        for byte in (frame(Data([1, 2, 3])) + frame(Data([4]))).utf8 {
            if let pcm = try parser.append(byte) { received.append(pcm) }
        }
        check(received == Data([1, 2, 3, 4]) && !parser.completed, "audio arrives before terminal marker")
        for byte in end.utf8 { _ = try parser.append(byte) }
        _ = try parser.finish()
        check(parser.completed, "terminal without final newline accepted")
        rejects("bytes after terminal rejected") { _ = try parser.append(0) }
        for (name, wire) in [
            ("missing terminal", frame(Data([1, 2]))),
            ("odd PCM sample at EOF", frame(Data([1])) + end),
            ("empty synthesis", end),
            ("malformed base64", "{\"code\":0,\"data\":\"!bad\"}\n" + end),
            ("malformed JSON", "{broken}\n"),
            ("error after audio", frame(Data([1, 2])) + "{\"code\":55000000,\"message\":\"private detail\"}\n")
        ] {
            rejects(name) {
                var p = XiaozhiVolcanoFrames()
                for b in wire.utf8 { _ = try p.append(b) }
                _ = try p.finish()
            }
        }
        do {
            var p = XiaozhiVolcanoFrames()
            for b in "{\"code\":45000000,\"message\":\"secret-response\"}\n".utf8 { _ = try p.append(b) }
            preconditionFailure("authorization error ignored")
        } catch {
            check(!error.localizedDescription.contains("secret-response"), "raw cloud body not exposed")
        }
        rejects("bounded unterminated JSON line") {
            var p = XiaozhiVolcanoFrames()
            for _ in 0...1_048_576 { _ = try p.append(32) }
        }

        var pcm = Data()
        for index in 0..<48_000 {
            var value = Int16(sin(Double(index) * 2 * .pi * 300 / 16000) * 9000).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let reference = try XiaozhiAudioCodec().encode(pcm)
        let encoder = XiaozhiStreamingEncoder()
        var packets: [Data] = [], offset = 0, chunk = 0
        let sizes = [1, 1919, 7, 3888, 321, 13, 4096]
        while offset < pcm.count {
            let end = min(pcm.count, offset + sizes[chunk % sizes.count])
            packets += try await encoder.append(Data(pcm[offset..<end]))
            offset = end; chunk += 1
        }
        check(!packets.isEmpty, "Opus produced before complete synthesis")
        packets += try await encoder.finish()
        check(packets == reference, "arbitrary PCM chunks preserve exact continuous Opus stream")
        let decoder = try XiaozhiAudioCodec()
        var decoded = Data()
        for packet in packets { decoded.append(try decoder.decode(packet)) }
        check(decoded.count == packets.count * 1920, "every streamed packet decodes to 60 ms at 16 kHz")
        do { _ = try await encoder.finish(); preconditionFailure("tail flushed twice") } catch { checks += 1 }
        do { _ = try await encoder.append(Data([0, 0])); preconditionFailure("audio after finish") } catch { checks += 1 }
        let truncated = XiaozhiStreamingEncoder()
        _ = try await truncated.append(Data([0]))
        do { _ = try await truncated.finish(); preconditionFailure("partial sample accepted") } catch { checks += 1 }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VolcanoFixtureProtocol.self]
        let speech = XiaozhiVolcanoSpeech(configuration: config)
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/tts/unidirectional")!)
        request.httpMethod = "POST"
        request.setValue("synthetic-test-key", forHTTPHeaderField: "X-Api-Key")
        VolcanoFixtureProtocol.body = Data((frame(Data([1, 2])) + frame(Data([3, 4])) + end + "\n").utf8)
        var delivered = Data()
        try await speech.stream(request) { delivered.append($0) }
        check(delivered == Data([1, 2, 3, 4]), "production HTTP client streams PCM")
        var callbacks = 0
        do {
            try await speech.stream(request) { _ in callbacks += 1; throw CancellationError() }
            preconditionFailure("consumer cancellation swallowed")
        } catch is CancellationError { check(callbacks == 1, "cancel stops delivery without retry") }
        delivered = Data()
        try await speech.stream(request) { delivered.append($0) }
        check(delivered.count == 4, "cancel releases client for next explicit request")
        VolcanoFixtureProtocol.body = Data(frame(Data([1, 2])).utf8)
        do {
            try await speech.stream(request) { _ in }
            preconditionFailure("EOF treated as success")
        } catch { checks += 1 }
        VolcanoFixtureProtocol.status = 403
        VolcanoFixtureProtocol.body = Data("private-error-body".utf8)
        do {
            try await speech.stream(request) { _ in preconditionFailure("HTTP error emitted audio") }
            preconditionFailure("HTTP auth failure ignored")
        } catch { check(!error.localizedDescription.contains("private-error-body"), "HTTP error body not leaked") }
        print("PASS \(checks) Volcano streaming checks; \(packets.count) continuous Opus packets")
    }
}

/// Intercepts the production HTTPS path; tests never contact a voice service.
private final class VolcanoFixtureProtocol: URLProtocol {
    static var body = Data()
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField: "X-Api-Key") == "synthetic-test-key")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
