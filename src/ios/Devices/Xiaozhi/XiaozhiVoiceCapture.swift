import Foundation
import RealTimeCutVADLibrary

/// Decoding and Silero inference stay off the main thread. The small pending
/// packet limit prevents a fast/misbehaving peer from growing the work queue.
final class XiaozhiVoiceCapture: NSObject, VADDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.openminis.xiaozhi.capture")
    private let pendingLock = NSLock()
    private var pendingPackets = 0
    private let result: (Result<Data, Error>) -> Void
    private var codec: XiaozhiAudioCodec?
    private var vad: VADWrapper?
    private var recording = Data()
    private var started = false
    private var listening = false
    private var auto = true
    private var totalFrames = 0

    init(result: @escaping (Result<Data, Error>) -> Void) {
        self.result = result
        super.init()
        queue.async {
            do { self.codec = try XiaozhiAudioCodec() }
            catch { self.result(.failure(error)) }
        }
    }

    func start(auto: Bool) {
        queue.async {
            self.auto = auto; self.recording.removeAll(keepingCapacity: true)
            self.started = false; self.totalFrames = 0
            guard let vad = VADWrapper() else {
                self.result(.failure(XiaozhiError.message("无法初始化语音分段"))); return
            }
            vad.setSileroModel(.v5); vad.setSamplerate(.SAMPLERATE_16)
            vad.setThresholdWithVadStartDetectionProbability(0.6, vadEndDetectionProbability: 0.45,
                voiceStartVadTrueRatio: 0.6, voiceEndVadFalseRatio: 0.9,
                voiceStartFrameCount: 6, voiceEndFrameCount: 28)
            vad.delegate = self; self.vad = vad; self.listening = true
        }
    }

    func append(_ packet: Data) {
        pendingLock.lock()
        guard pendingPackets < 50 else {
            pendingLock.unlock(); result(.failure(XiaozhiError.message("设备发送语音过快"))); return
        }
        pendingPackets += 1; pendingLock.unlock()
        queue.async {
            defer { self.pendingLock.lock(); self.pendingPackets -= 1; self.pendingLock.unlock() }
            guard self.listening, let codec = self.codec else { return }
            do {
                let pcm = try codec.decode(packet)
                self.totalFrames += 1
                self.recording.append(pcm)
                if !self.started, self.recording.count > 16_000 * 2 {
                    self.recording = Data(self.recording.suffix(16_000 * 2))
                }
                let samples = pcm.withUnsafeBytes { raw -> [Float] in
                    raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
                }
                samples.withUnsafeBufferPointer { buffer in
                    if let base = buffer.baseAddress { self.vad?.processAudioData(withBuffer: base, count: UInt(buffer.count)) }
                }
                if self.listening, self.recording.count >= XiaozhiProtocol.maxRecordingBytes {
                    self.finishOnQueue()
                }
            } catch {
                self.listening = false; self.result(.failure(error))
            }
        }
    }

    func finish() { queue.async { self.finishOnQueue() } }

    func cancel() {
        queue.async {
            self.listening = false; self.vad?.delegate = nil; self.vad = nil
            self.recording.removeAll()
        }
    }

    private func finishOnQueue() {
        guard listening else { return }
        listening = false
        let pcm = started ? recording.prefix(XiaozhiProtocol.maxRecordingBytes) : Data()
        recording.removeAll(keepingCapacity: true)
        result(.success(pcm.isEmpty ? Data() : XiaozhiProtocol.wav(pcm: Data(pcm))))
    }

    // VADWrapper invokes delegates synchronously on its processing thread.
    func voiceStarted() { started = true }
    func voiceEnded(withWavData wavData: Data!) { if auto { finishOnQueue() } }
    func voiceDidContinue(withPCMFloat pcmFloatData: Data!) {}
}
