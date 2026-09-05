import Foundation

/// One live conversation with Gemini.
///
/// The phone talks to Google directly — the backend only mints the short-lived
/// token this is opened with. Nothing about the audio path goes through our
/// own server, because a relay hop on every chunk is exactly the latency the
/// product is trying not to have.
final class GeminiLiveSession: NSObject {

  enum Event {
    case ready
    /// Raw 16-bit little-endian PCM at 24 kHz, ready to play.
    case audio(Data)
    /// A fragment of what Ordi is saying, as it says it. Arrives independently
    /// of the audio and carries no ordering guarantee against it.
    case transcript(String)
    /// The user cut Ordi off. Anything already buffered must be thrown away.
    case interrupted
    /// Ordi finished its turn.
    case turnComplete
    case closed(String?)
    case failed(String)
  }

  var onEvent: ((Event) -> Void)?

  private var socket: URLSessionWebSocketTask?
  private var session: URLSession?
  private let model: String

  /// Outbound audio is serialised off the realtime thread. Encoding and
  /// sending must never happen on the audio callback.
  private let sendQueue = DispatchQueue(label: "ordi.gemini.send")

  /// Read from the realtime audio thread and written from URLSession's queue,
  /// so both need guarding however small they look.
  private let flags = NSLock()
  private var _isOpen = false
  private var _didSendSetup = false

  private var isOpen: Bool {
    get { flags.lock(); defer { flags.unlock() }; return _isOpen }
    set { flags.lock(); _isOpen = newValue; flags.unlock() }
  }

  private var didSendSetup: Bool {
    get { flags.lock(); defer { flags.unlock() }; return _didSendSetup }
    set { flags.lock(); _didSendSetup = newValue; flags.unlock() }
  }

  init(model: String) {
    self.model = model
    super.init()
  }

  // MARK: - Connecting

  /// `token` is the ephemeral token from our backend, not the API key.
  func connect(token: String) {
    // Three things here are load-bearing, and getting any of them wrong
    // produces the same misleading "unregistered callers" error:
    //
    //  1. v1alpha — ephemeral tokens exist in no other API version.
    //  2. BidiGenerateContentConstrained — the *constrained* method is the one
    //     that accepts a token. Plain BidiGenerateContent demands a real API
    //     key and rejects tokens as anonymous.
    //  3. The token is interpolated raw. It contains a slash
    //     ("auth_tokens/..."), and percent-encoding it — which URLComponents
    //     does by default — makes the server reject it.
    let endpoint = "wss://generativelanguage.googleapis.com/ws/"
      + "google.ai.generativelanguage.v1alpha.GenerativeService"
      + ".BidiGenerateContentConstrained"

    guard let url = URL(string: "\(endpoint)?access_token=\(token)") else {
      onEvent?(.failed("Could not build the Live API URL."))
      return
    }

    let configuration = URLSessionConfiguration.default
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = 30

    let session = URLSession(
      configuration: configuration, delegate: self, delegateQueue: nil)
    let socket = session.webSocketTask(with: url)

    self.session = session
    self.socket = socket

    socket.resume()
    receiveNext()
    sendSetup()
  }

  func close() {
    // Drop the callback first: everything that follows produces cancellations,
    // and none of it is news to anyone.
    onEvent = nil
    isOpen = false
    didSendSetup = false
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    session?.invalidateAndCancel()
    session = nil
  }

  // MARK: - Sending

  private func sendSetup() {
    // The token already pins the model, modalities and system instruction
    // server-side; this states the same thing rather than contradicting it.
    let setup: [String: Any] = [
      "setup": [
        "model": "models/\(model)",
        "generationConfig": ["responseModalities": ["AUDIO"]],
        "outputAudioTranscription": [:],
      ]
    ]
    send(json: setup) { [weak self] in self?.didSendSetup = true }
  }

  /// Queues one chunk of microphone audio: raw 16-bit little-endian PCM,
  /// 16 kHz mono. Note the rate differs from what comes back.
  ///
  /// Called from the realtime audio thread, so it does no work here — base64
  /// and JSON encoding both happen on `sendQueue`.
  func send(audio: Data) {
    guard !audio.isEmpty else { return }
    sendQueue.async { [weak self] in
      guard let self, self.isOpen, self.didSendSetup else { return }
      let payload: [String: Any] = [
        "realtimeInput": [
          "audio": [
            "mimeType": "audio/pcm;rate=16000",
            "data": audio.base64EncodedString(),
          ]
        ]
      ]
      self.write(payload)
    }
  }

  /// Sends a typed question, as if the user had spoken it. Used for questions
  /// arriving from Siri, where the words are already text.
  func send(text: String) {
    guard !text.isEmpty else { return }
    sendQueue.async { [weak self] in
      guard let self, self.isOpen, self.didSendSetup else { return }
      self.write([
        "clientContent": [
          "turns": [["role": "user", "parts": [["text": text]]]],
          "turnComplete": true,
        ]
      ])
    }
  }

  private func send(json object: [String: Any], then done: (() -> Void)? = nil) {
    sendQueue.async { [weak self] in
      self?.write(object, then: done)
    }
  }

  /// Must be called on `sendQueue`.
  private func write(_ object: [String: Any], then done: (() -> Void)? = nil) {
    guard let socket else { return }
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    let text = String(decoding: data, as: UTF8.self)

    socket.send(.string(text)) { [weak self] error in
      guard let error else {
        done?()
        return
      }
      // Closing a session cancels whatever was in flight on it. Audio is
      // streaming continuously, so there is essentially always something in
      // flight — reporting that as a failure means every normal disconnect
      // shows the user an error.
      if (error as NSError).code == NSURLErrorCancelled { return }
      self?.onEvent?(.failed("Send failed: \(error.localizedDescription)"))
    }
  }

  // MARK: - Receiving

  private func receiveNext() {
    socket?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        // A cancelled socket is an ordinary shutdown, not a failure worth
        // surfacing to the user.
        let code = (error as NSError).code
        if code != NSURLErrorCancelled {
          self.onEvent?(.failed(error.localizedDescription))
        }

      case .success(let message):
        switch message {
        case .string(let text):
          self.handle(Data(text.utf8))
        case .data(let data):
          self.handle(data)
        @unknown default:
          break
        }
        self.receiveNext()
      }
    }
  }

  private func handle(_ data: Data) {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }

    if root["setupComplete"] != nil {
      isOpen = true
      onEvent?(.ready)
      return
    }

    guard let content = root["serverContent"] as? [String: Any] else { return }

    // Order matters. An interruption invalidates audio that may be sitting in
    // the same message, so act on it before queueing anything.
    if content["interrupted"] as? Bool == true {
      onEvent?(.interrupted)
    }

    if let transcription = content["outputTranscription"] as? [String: Any],
       let text = transcription["text"] as? String,
       !text.isEmpty {
      onEvent?(.transcript(text))
    }

    if let turn = content["modelTurn"] as? [String: Any],
       let parts = turn["parts"] as? [[String: Any]] {
      for part in parts {
        guard
          let inline = part["inlineData"] as? [String: Any],
          let encoded = inline["data"] as? String,
          let audio = Data(base64Encoded: encoded)
        else { continue }
        onEvent?(.audio(audio))
      }
    }

    if content["turnComplete"] as? Bool == true {
      onEvent?(.turnComplete)
    }
  }
}

// MARK: - Socket lifecycle

extension GeminiLiveSession: URLSessionWebSocketDelegate {
  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol proto: String?
  ) {
    // The socket is up, but the conversation is not usable until the server
    // acknowledges setup — `ready` is emitted there, not here.
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    isOpen = false
    let text = reason.flatMap { String(data: $0, encoding: .utf8) }
    onEvent?(.closed(text?.isEmpty == false ? text : nil))
  }
}
