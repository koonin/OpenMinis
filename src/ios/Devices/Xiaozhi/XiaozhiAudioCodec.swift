import AVFoundation
import AudioToolbox
import Foundation

/// Serially owned by a capture worker. Uses the system Opus codec; no microphone
/// or playback audio session is acquired on the iPhone.
final class XiaozhiAudioCodec {
    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let decoder: AVAudioConverter
    private var firstPacket = true

    init() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                      channels: 1, interleaved: true),
              let decoder = AVAudioConverter(from: opus, to: pcm) else {
            throw XiaozhiError.message("此设备无法初始化小智音频格式")
        }
        decoder.primeMethod = .none
        pcmFormat = pcm; opusFormat = opus; self.decoder = decoder
    }

    func decode(_ packet: Data) throws -> Data {
        guard packet.count <= 4096, XiaozhiProtocol.is60msMonoOpus(packet) else {
            throw XiaozhiError.message("无效的语音数据，需要 60 毫秒单声道 Opus")
        }
        let input = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: 4096)
        input.packetCount = 1; input.byteLength = UInt32(packet.count)
        packet.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: packet.count)
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 960, mDataByteSize: UInt32(packet.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1920) else {
            throw XiaozhiError.message("无法创建音频缓冲区")
        }
        var supplied = false
        var error: NSError?
        let status = decoder.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard error == nil, status != .error,
              output.frameLength == 960 || (firstPacket && output.frameLength == 920),
              let samples = output.int16ChannelData?[0] else {
            throw XiaozhiError.message("小智音频需要 16 kHz 单声道、60 毫秒帧")
        }
        // Core Audio trims 40 initial samples even with primeMethod=.none.
        // Restore only that first packet's leading silence to retain the exact
        // device clock; later packets must decode to the full 960 samples.
        firstPacket = false
        var pcm = Data(repeating: 0, count: (960 - Int(output.frameLength)) * 2)
        pcm.append(Data(bytes: samples, count: Int(output.frameLength) * 2))
        return pcm
    }

    /// Convert a complete synthesized audio file to mono PCM, bounded to 90 s.
    static func pcmFromAudio(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024 else {
            throw XiaozhiError.message("回复音频为空或过大")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xiaozhi-tts-\(UUID()).audio")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard source.sampleRate > 0, file.length > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                        channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            throw XiaozhiError.message("无法转换回复音频")
        }
        var pcm = Data(), readError: Error?
        let limit = 90 * 16_000 * 2
        while pcm.count < limit {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                let remaining = file.length - file.framePosition
                guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: input, frameCount: AVAudioFrameCount(min(4096, remaining)))
                    state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readError = error; state.pointee = .endOfStream; return nil
                }
            }
            if let readError { throw readError }
            guard status != .error, error == nil else { throw XiaozhiError.message("回复音频转换失败") }
            if let samples = output.int16ChannelData?[0], output.frameLength > 0 {
                pcm.append(Data(bytes: samples, count: min(Int(output.frameLength) * 2, limit - pcm.count)))
            }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        guard !pcm.isEmpty else { throw XiaozhiError.message("回复没有可播放的音频") }
        return pcm
    }

    /// Encode the entire reply with one converter, preserving codec lookahead
    /// across packets and flushing its final tail once at end-of-stream.
    func encode(_ pcm: Data) throws -> [Data] {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 90 * 16_000 * 2,
              let encoder = AVAudioConverter(from: pcmFormat, to: opusFormat),
              let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let samples = input.int16ChannelData?[0] else { throw XiaozhiError.message("回复音频格式错误") }
        input.frameLength = AVAudioFrameCount(pcm.count / 2)
        pcm.copyBytes(to: UnsafeMutableRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: pcm.count)
        encoder.bitRate = 24_000
        let output = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 16, maximumPacketSize: 4096)
        var packets: [Data] = [], supplied = false
        while packets.count < 1600 {
            var error: NSError?
            let status = encoder.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            guard status != .error, error == nil else { throw XiaozhiError.message("回复音频编码失败") }
            for index in 0..<Int(output.packetCount) {
                guard let packet = output.packetDescriptions?[index], packet.mDataByteSize > 0,
                      packet.mDataByteSize <= 4096 else { throw XiaozhiError.message("无效的编码音频") }
                let bytes = Data(bytes: output.data.advanced(by: Int(packet.mStartOffset)),
                                 count: Int(packet.mDataByteSize))
                guard XiaozhiProtocol.is60msMonoOpus(bytes) else {
                    throw XiaozhiError.message("系统编码器未返回小智需要的音频帧")
                }
                packets.append(bytes)
            }
            if status == .endOfStream || output.packetCount == 0 { break }
        }
        guard !packets.isEmpty else { throw XiaozhiError.message("回复音频编码为空") }
        return packets
    }
}

/// One encoder for the entire PCM stream. Chunk boundaries never flush Opus
/// lookahead; only the explicit successful end-of-stream flushes its tail.
/// Actor ownership keeps codec work off the UI and serializes all input.
actor XiaozhiStreamingEncoder {
    private var encoder: AVAudioConverter?
    private var pcmFormat: AVAudioFormat?
    private var opusFormat: AVAudioFormat?
    private var pending = Data()
    private var totalBytes = 0
    private var totalPackets = 0
    private var finished = false

    func append(_ data: Data) throws -> [Data] {
        guard !finished, totalBytes + data.count <= 90 * 16_000 * 2 else {
            throw XiaozhiError.message("语音流已结束或超过时长限制")
        }
        totalBytes += data.count
        pending.append(data)
        return try convert(final: false)
    }

    func finish() throws -> [Data] {
        guard !finished, totalBytes > 0, totalBytes % 2 == 0 else {
            throw XiaozhiError.message("语音流为空、不完整或已经结束")
        }
        finished = true
        return try convert(final: true)
    }

    private func convert(final: Bool) throws -> [Data] {
        if encoder == nil {
            var description = AudioStreamBasicDescription(
                mSampleRate: 16_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
            guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                          channels: 1, interleaved: true),
                  let opus = AVAudioFormat(streamDescription: &description),
                  let converter = AVAudioConverter(from: pcm, to: opus) else {
                throw XiaozhiError.message("无法初始化流式声音编码")
            }
            converter.bitRate = 24_000
            pcmFormat = pcm; opusFormat = opus; encoder = converter
        }
        guard let encoder, let pcmFormat, let opusFormat else { throw XiaozhiError.message("声音编码器不可用") }
        let output = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 16, maximumPacketSize: 1275)
        let input = XiaozhiPCMInput(data: pending, format: pcmFormat, final: final)
        defer { pending.removeFirst(input.consumed) }
        var packets: [Data] = []
        while true {
            var failure: NSError?
            let status = encoder.convert(to: output, error: &failure) { requested, state in
                input.read(requested, state: state)
            }
            guard !input.failed, failure == nil, status != .error else {
                throw XiaozhiError.message("流式声音编码失败")
            }
            for index in 0..<Int(output.packetCount) {
                guard let description = output.packetDescriptions?[index],
                      description.mDataByteSize > 0, description.mDataByteSize <= 1275 else {
                    throw XiaozhiError.message("流式声音帧无效")
                }
                let packet = Data(bytes: output.data.advanced(by: Int(description.mStartOffset)),
                                  count: Int(description.mDataByteSize))
                guard XiaozhiProtocol.is60msMonoOpus(packet), totalPackets < 1502 else {
                    throw XiaozhiError.message("流式声音帧格式或时长异常")
                }
                packets.append(packet); totalPackets += 1
            }
            if status == .endOfStream || status == .inputRanDry || output.packetCount == 0 { break }
        }
        return packets
    }
}

/// AudioConverter's callback is Sendable. Its cursor is independent of actor
/// state and protected even if the converter invokes it on another thread.
private final class XiaozhiPCMInput: @unchecked Sendable {
    private let data: Data
    private let format: AVAudioFormat
    private let final: Bool
    private let lock = NSLock()
    private var offset = 0
    private var inputFailed = false
    var consumed: Int { lock.lock(); defer { lock.unlock() }; return offset }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return inputFailed }

    init(data: Data, format: AVAudioFormat, final: Bool) {
        self.data = data; self.format = format; self.final = final
    }

    func read(_ requested: UInt32, state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        let available = (data.count - offset) / 2
        guard available > 0 else {
            state.pointee = final ? .endOfStream : .noDataNow
            return nil
        }
        let count = min(Int(requested), available)
        guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let samples = input.int16ChannelData?[0] else {
            inputFailed = true; state.pointee = .noDataNow; return nil
        }
        input.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(samples, base.advanced(by: offset), count * 2) }
        }
        offset += count * 2
        state.pointee = .haveData
        return input
    }
}
