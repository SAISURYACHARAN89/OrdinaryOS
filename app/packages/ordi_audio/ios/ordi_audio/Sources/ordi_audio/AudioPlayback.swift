import AVFoundation

/// Plays Ordi's voice, and — more importantly — stops it instantly.
///
/// Gemini streams 24 kHz PCM back in chunks, which we queue on a player node.
/// The queue is what makes barge-in subtle: when the user interrupts, the model
/// stops generating immediately, but whatever we have already buffered would
/// keep playing for a second or so. That trailing second is exactly what makes
/// an assistant feel like a walkie-talkie, so `flush()` throws the queue away
/// rather than letting it drain.
///
/// **Threading**: `enqueue` and `flush` must be called from the engine's control
/// queue, never from the realtime audio thread — `AVAudioPlayerNode.stop()`
/// takes locks the render thread must not wait on. The queue depth is guarded
/// because scheduling completions land on an arbitrary thread.
final class AudioPlayback {

  /// Gemini's output rate. Note it differs from the 16 kHz we send up.
  static let sampleRate: Double = 24_000

  private let player = AVAudioPlayerNode()
  private let format: AVAudioFormat

  /// Playback level, 0..1, so the orb can move with Ordi's own voice.
  var onLevel: ((Float) -> Void)?

  /// Fires when the queue empties — the model has finished speaking and we
  /// have actually played all of it.
  var onFinished: (() -> Void)?

  private let lock = NSLock()
  private var scheduledChunks = 0
  private var started = false

  /// Bumped on every flush so that completions belonging to discarded buffers
  /// cannot report the queue as empty after a newer turn has already started.
  private var generation = 0

  init?() {
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Self.sampleRate,
      channels: 1,
      interleaved: false
    ) else { return nil }
    self.format = format
  }

  // MARK: - Wiring

  func attach(to engine: AVAudioEngine) {
    engine.attach(player)
    // Connecting at 24 kHz lets the engine resample to the hardware rate for
    // us, which is both correct and cheaper than doing it by hand.
    engine.connect(player, to: engine.mainMixerNode, format: format)

    // Tap the player rather than estimating from what we enqueue: this is the
    // audio as it actually plays, so the orb stays in step with the voice
    // instead of running ahead of it.
    player.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.report(buffer)
    }
  }

  func detach(from engine: AVAudioEngine) {
    player.removeTap(onBus: 0)
    if player.engine != nil { engine.detach(player) }
    lock.lock()
    started = false
    scheduledChunks = 0
    generation &+= 1
    lock.unlock()
  }

  // MARK: - Playing

  /// Queues one chunk of raw 16-bit little-endian PCM at 24 kHz.
  func enqueue(pcm16 data: Data) {
    guard !data.isEmpty, let buffer = makeBuffer(from: data) else { return }

    lock.lock()
    if !started {
      player.play()
      started = true
    }
    scheduledChunks += 1
    let era = generation
    lock.unlock()

    player.scheduleBuffer(buffer) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      // A flush happened while this buffer was in flight; its completion says
      // nothing about the current turn.
      guard era == self.generation else {
        self.lock.unlock()
        return
      }
      self.scheduledChunks -= 1
      let drained = self.scheduledChunks == 0
      self.lock.unlock()

      if drained {
        self.onLevel?(0)
        self.onFinished?()
      }
    }
  }

  /// Drops everything queued and not yet heard. This is barge-in.
  ///
  /// `stop()` discards scheduled buffers rather than draining them, which is
  /// precisely the behaviour we want and the reason it is used here instead of
  /// `pause()`. Must not be called from the realtime audio thread.
  func flush() {
    lock.lock()
    generation &+= 1
    scheduledChunks = 0
    started = false
    lock.unlock()

    player.stop()
    onLevel?(0)
  }

  var isSpeaking: Bool {
    lock.lock()
    defer { lock.unlock() }
    return scheduledChunks > 0
  }

  // MARK: - Conversion

  /// 16-bit signed little-endian -> normalised float, which is what the engine
  /// wants and what the level meter reads.
  private func makeBuffer(from data: Data) -> AVAudioPCMBuffer? {
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard
      sampleCount > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
      let channel = buffer.floatChannelData?[0]
    else { return nil }

    buffer.frameLength = AVAudioFrameCount(sampleCount)

    data.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      for i in 0..<sampleCount {
        // Read byte-wise: the incoming buffer carries no alignment guarantee,
        // so loading Int16 directly can trap.
        let lo = UInt16(base[i * 2])
        let hi = UInt16(base[i * 2 + 1])
        let sample = Int16(bitPattern: lo | (hi << 8))
        channel[i] = Float(sample) / 32_768.0
      }
    }
    return buffer
  }

  private func report(_ buffer: AVAudioPCMBuffer) {
    guard let channel = buffer.floatChannelData?[0], let onLevel else { return }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return }

    var sum: Float = 0
    for i in 0..<count { sum += channel[i] * channel[i] }
    let rms = sqrt(sum / Float(count))

    // Same dBFS mapping as the microphone side, so the orb reacts to Ordi's
    // voice the way it reacts to the user's.
    let level: Float
    if rms > 0 {
      let db = 20 * log10(rms)
      level = (min(max(db, -52), -12) + 52) / 40
    } else {
      level = 0
    }
    onLevel(level)
  }
}
