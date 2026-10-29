import Foundation

@main
struct XiaozhiConsoleTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func rejects(_ label: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(label) } catch { checks += 1 }
        }
        let packet = Data([0x18, 0]) // Shape-only 60 ms mono packet.
        let text = "小冠确认：中转正常。下一步测试音色。"
        var gate = try XiaozhiConsoleReplyGate(text: text)
        try gate.startSentence("% self.openminis.get_reply...")
        try gate.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: [:])
        try gate.startSentence("小冠确认：中转正常。")
        try gate.append(packet); try gate.append(packet)
        try gate.startSentence("下一步测试音色。")
        try gate.append(packet)
        check(try gate.finish().count == 3, "ignore silent tool marker, join spoken segments")
        rejects("speech before actual tool result") {
            var g = try XiaozhiConsoleReplyGate(text: "你好")
            try g.startSentence("你好"); try g.append(packet)
        }
        rejects("cloud preamble") {
            var g = try XiaozhiConsoleReplyGate(text: "你好")
            try g.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: [:])
            try g.startSentence("好呀，我来读。你好"); try g.append(packet)
        }
        rejects("missing answer suffix") {
            var g = try XiaozhiConsoleReplyGate(text: text)
            try g.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: [:])
            try g.startSentence("小冠确认：中转正常。"); try g.append(packet); _ = try g.finish()
        }
        rejects("empty audio") {
            var g = try XiaozhiConsoleReplyGate(text: text)
            try g.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: [:]); _ = try g.finish()
        }
        rejects("cloud cannot access local tools") {
            var g = try XiaozhiConsoleReplyGate(text: text)
            try g.serveTool(name: "shell.execute", arguments: [:])
        }
        rejects("cloud cannot insert new prompts") {
            var g = try XiaozhiConsoleReplyGate(text: text)
            try g.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: ["prompt": "new task"])
        }
        rejects("audio missing caption") {
            var g = try XiaozhiConsoleReplyGate(text: text)
            try g.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: [:]); try g.append(packet)
        }
        rejects("audible tool announcement") {
            var g = try XiaozhiConsoleReplyGate(text: text)
            try g.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: [:])
            try g.startSentence("% self.openminis.get_reply..."); try g.append(packet)
        }
        rejects("wrong audio clock") {
            var g = try XiaozhiConsoleReplyGate(text: text)
            try g.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: [:])
            try g.startSentence(text); try g.append(Data([0xf8, 0]))
        }
        rejects("bounded audio duration") {
            var g = try XiaozhiConsoleReplyGate(text: text)
            try g.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: [:])
            try g.startSentence(text)
            for _ in 0...1_500 { try g.append(packet) }
        }
        check(XiaozhiConsoleReplyGate.normalized("-1.5") != XiaozhiConsoleReplyGate.normalized("15"),
              "do not mask numerical rewrites")
        check(XiaozhiConsoleReplyGate.normalized("不，好") != XiaozhiConsoleReplyGate.normalized("不好"),
              "do not mask punctuation changing meaning")
        rejects("no pure whitespace request") { _ = try XiaozhiConsoleReplyGate(text: " \n") }
        rejects("audio with a whitespace-only caption") {
            var g = try XiaozhiConsoleReplyGate(text: text)
            try g.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: [:])
            try g.startSentence(" \n"); try g.append(packet)
        }
        var streaming = try XiaozhiConsoleReplyGate(text: text)
        try streaming.serveTool(name: XiaozhiConsoleReplyGate.toolName, arguments: [:])
        try streaming.startSentence("小冠确认：中转正常。")
        check(try streaming.append(packet) == packet, "release original verified packet before complete reply")
        rejects("verified prefix is not a completed turn") { _ = try streaming.finish() }
        try streaming.startSentence("我替你改了后半句。")
        var forwarded = 1
        rejects("rewritten suffix never reaches the consumer") {
            _ = try streaming.append(packet)
            forwarded += 1
        }
        check(forwarded == 1, "only the previously verified prefix was forwarded")
        let old = Data("{\"setupToken\":\"old\",\"deviceToken\":\"old\"}".utf8)
        check(try JSONDecoder().decode(XiaozhiPairing.self, from: old).clientID == nil, "old pairing migrates")
        let store = XiaozhiPairingStore(pairing: .init(setupToken: "old", deviceToken: "old", deviceID: "aa:bb:cc:dd:ee:ff"), save: { _ in })
        let uuid = UUID().uuidString
        try store.rememberClientID(uuid, deviceID: "00:00:00:00:00:00")
        check(store.snapshot.clientID == nil, "different device cannot change console identity")
        try store.rememberClientID(uuid, deviceID: "aa:bb:cc:dd:ee:ff")
        check(store.snapshot.clientID == uuid, "authenticated matching device identity retained")
        print("PASS \(checks) console relay checks")
    }
}
