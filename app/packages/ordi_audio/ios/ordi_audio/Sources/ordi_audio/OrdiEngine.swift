import AVFoundation
import os

/// The whole realtime path: microphone in, Ordi's voice out, and the barge-in
/// that makes it feel like a conversation instead of a walkie-talkie.
///
/// **Threading rule, and it is not optional.** The audio tap runs on a realtime
/// thread that must never block. It is allowed to do arithmetic on the samples
/// and nothing else. Every decision that follows — voice activity, state
/// changes, starting or stopping playback — is handed to `control`, a serial
/// queue that owns all of that mutable state.
///
/// Calling `AVAudioPlayerNode.stop()` from the render thread takes locks the
/// render thread must not wait on, which is a crash rather than a slowdown.
final class OrdiEngine {

  enum State: String {
    case idle, listening, thinking, speaking
  }

  var onState: ((State) -> Void)?
  var onLevel: ((Float) -> Void)?
  var onError: ((String) -> Void)?
  /// The whole of what Ordi is currently saying, growing as it speaks.
  var onTranscript: ((String) -> Void)?

  private let engine = AVAudioEngine()
  private var playback: AudioPlayback?
  private var live: GeminiLiveSession?

  /// Owns every piece of mutable state below. Serial, so no locks are needed
  /// as long as nothing touches them from anywhere else.
  private let control = DispatchQueue(label: "ordi.engine.control")

  /// Visible with: log stream --device-udid <id> --predicate 'subsystem == "com.atmosphere.ordi"'
  private let log = Logger(subsystem: "com.atmosphere.ordi", category: "engine")

  private var running = false
  private var state: State = .idle
  private var userSpeaking = false
  private var framesAboveOn = 0
  private var quietFrames = 0

  /// What Ordi is saying this turn. Arrives in fragments and is cleared when
  /// the next turn begins, not when this one ends — the words should stay on
  /// screen to be read after Ordi stops talking.
  private var transcript = ""

  /// Read from the method channel, so it needs to be safe off-queue.
  private let runningLock = NSLock()
  private(set) var isRunning: Bool {
    get { runningLock.lock(); defer { runningLock.unlock() }; return running }
    set { runningLock.lock(); running = newValue; runningLock.unlock() }
  }

  // Hysteresis, so one loud frame or one breath mid-sentence does not flap the
  // orb. Starting is deliberately harder than continuing.
  private let onThreshold: Float = 0.14
  private let offThreshold: Float = 0.07
  private let framesToStart = 2    // ~40ms of sustained level
  private let framesToStop = 28    // ~600ms of quiet

  private var converter: AVAudioConverter?
  private let uplinkFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)

  // MARK: - Lifecycle

  func start() throws {
    guard !isRunning else { return }

    // .voiceChat is what turns on Apple's hardware echo cancellation. Without
    // it Ordi hears itself through the speaker and interrupts its own sentence
    // the moment it starts talking — which would break the one behaviour the
    // product is judged on.
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
    try audioSession.setPreferredIOBufferDuration(0.02)
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

    let input = engine.inputNode
    _ = engine.outputNode  // instantiate the voice-processing unit both ways
    try input.setVoiceProcessingEnabled(true)
    try engine.outputNode.setVoiceProcessingEnabled(true)

    let playback = AudioPlayback()
    playback?.attach(to: engine)
    playback?.onLevel = { [weak self] level in
      guard let self else { return }
      self.control.async {
        guard self.state == .speaking else { return }
        self.emitLevel(level)
      }
    }
    playback?.onFinished = { [weak self] in
      guard let self else { return }
      self.control.async {
        guard self.state == .speaking else { return }
        self.setState(.idle)
      }
    }
    self.playback = playback

    let tapFormat = input.outputFormat(forBus: 0)
    guard tapFormat.sampleRate > 0 else {
      throw NSError(
        domain: "ordi.audio", code: -1,
        userInfo: [NSLocalizedDescriptionKey:
          "Input format unavailable — is another app holding the microphone?"])
    }
    if let uplinkFormat {
      converter = AVAudioConverter(from: tapFormat, to: uplinkFormat)
    }

    input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
      self?.process(buffer)
    }

    engine.prepare()
    try engine.start()
    isRunning = true
    control.async {
      self.resetVoiceActivity()
      self.setState(.idle)
    }
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    engine.inputNode.removeTap(onBus: 0)

    control.sync {
      playback?.flush()
      playback?.detach(from: engine)
      playback = nil
      resetVoiceActivity()
      transcript = ""
      emitTranscript()
      setState(.idle)
    }

    engine.stop()
    converter = nil
    emitLevel(0)
    try? AVAudioSession.sharedInstance().setActive(
      false, options: .notifyOthersOnDeactivation)
  }

  // MARK: - The conversation

  func connect(token: String, model: String) {
    // Reconnecting on top of a working session cancels every audio send that
    // was in flight and costs a fresh token for no gain. The app can call this
    // more than once — on launch and again on resume — so absorb it here
    // rather than relying on every caller to remember.
    if live != nil {
      log.notice("connect ignored — a session is already open")
      return
    }
    log.notice("opening a session")

    let live = GeminiLiveSession(model: model)
    live.onEvent = { [weak self] event in
      guard let self else { return }
      // Socket callbacks arrive on URLSession's queue; funnel them in.
      self.control.async { self.handle(event) }
    }
    live.connect(token: token)
    self.live = live
  }

  private func handle(_ event: GeminiLiveSession.Event) {
    switch event {
    case .ready:
      setState(.idle)

    case .audio(let data):
      // Audio arriving means Ordi has started answering.
      if state != .speaking { setState(.speaking) }
      playback?.enqueue(pcm16: data)

    case .transcript(let fragment):
      transcript += fragment
      emitTranscript()

    case .interrupted:
      // The server noticed the user talking over Ordi. We have usually
      // already flushed locally; this covers the cases we missed.
      playback?.flush()
      setState(userSpeaking ? .listening : .idle)

    case .turnComplete:
      // Not idle yet — there is still queued audio to hear. AudioPlayback
      // reports when the queue actually empties.
      break

    case .closed(let reason):
      log.error("session closed: \(reason ?? "no reason", privacy: .public)")
      // Release the session so a later connect can replace it. Tokens expire
      // after ten minutes, so a dead session that still looks alive would
      // block reconnection permanently.
      live = nil
      setState(.idle)
      if let reason { onError?("Connection closed: \(reason)") }

    case .failed(let message):
      log.error("session failed: \(message, privacy: .public)")
      live = nil
      setState(.idle)
      onError?(message)
    }
  }

  func disconnect() {
    live?.close()
    live = nil
    control.async {
      self.playback?.flush()
      self.setState(.idle)
    }
  }

  private var isConnected: Bool { live != nil }

  // MARK: - Audio thread
  //
  // Everything in this section runs on the realtime thread. Arithmetic only.

  private func process(_ buffer: AVAudioPCMBuffer) {
    guard let channel = buffer.floatChannelData?[0] else { return }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return }

    var sum: Float = 0
    for i in 0..<count { sum += channel[i] * channel[i] }
    let level = normalise(sqrt(sum / Float(count)))

    // Conversion is pure DSP and safe here; encoding and sending are not, and
    // happen on the session's own queue.
    if let data = convert(buffer) {
      live?.send(audio: data)
    }

    control.async { self.consider(level: level) }
  }

  /// RMS is linear and tiny; hearing is logarithmic. Map dBFS across the range
  /// speech actually occupies on a phone held at arm's length.
  private func normalise(_ rms: Float) -> Float {
    guard rms > 0 else { return 0 }
    let db = 20 * log10(rms)
    return (min(max(db, -52), -12) + 52) / 40
  }

  /// Hardware format -> 16 kHz mono 16-bit, which is what the Live API wants.
  private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
    guard let converter, let uplinkFormat, buffer.frameLength > 0 else { return nil }

    let ratio = uplinkFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
    guard let out = AVAudioPCMBuffer(pcmFormat: uplinkFormat, frameCapacity: capacity)
    else { return nil }

    var consumed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }

    guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData
    else { return nil }
    return Data(bytes: samples[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
  }

  // MARK: - Control queue
  //
  // Everything below runs serialised on `control`.

  private func consider(level: Float) {
    // Being stuck in .speaking is the worst failure this engine has: the orb
    // stops following the user entirely, so it looks deaf. AVAudioPlayerNode
    // does not guarantee a completion handler for every scheduled buffer, so
    // leaving .speaking cannot depend on one arriving. Check the queue itself.
    if state == .speaking && playback?.isSpeaking != true {
      log.notice("playback drained without a completion — recovering to idle")
      setState(.idle)
    }

    updateVoiceActivity(level)

    // Only the user's level drives the orb while they speak; during playback
    // the orb follows Ordi's voice instead.
    if state != .speaking {
      emitLevel(level)
    }
  }

  private func updateVoiceActivity(_ level: Float) {
    if userSpeaking {
      quietFrames = level < offThreshold ? quietFrames + 1 : 0
      if quietFrames >= framesToStop {
        userSpeaking = false
        quietFrames = 0
        // They stopped. If a session is live, the model is now composing.
        if isConnected && state == .listening { setState(.thinking) }
      }
    } else {
      framesAboveOn = level > onThreshold ? framesAboveOn + 1 : 0
      if framesAboveOn >= framesToStart {
        userSpeaking = true
        framesAboveOn = 0
        beginListening()
      }
    }
  }

  /// Barge-in. Cut playback the moment the user starts talking rather than
  /// waiting for the server to tell us it was interrupted — that round trip is
  /// the difference between "it stopped when I spoke" and "it talked over me".
  private func beginListening() {
    if state == .speaking {
      playback?.flush()
    }
    // A new question replaces the last answer on screen.
    if !transcript.isEmpty {
      transcript = ""
      emitTranscript()
    }
    setState(.listening)
  }

  private func resetVoiceActivity() {
    userSpeaking = false
    framesAboveOn = 0
    quietFrames = 0
  }

  private func setState(_ next: State) {
    guard next != state else { return }
    log.notice("state \(self.state.rawValue, privacy: .public) -> \(next.rawValue, privacy: .public)")
    state = next
    DispatchQueue.main.async { [weak self] in self?.onState?(next) }
  }

  private func emitLevel(_ level: Float) {
    DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
  }

  private func emitTranscript() {
    let text = transcript
    DispatchQueue.main.async { [weak self] in self?.onTranscript?(text) }
  }
}
