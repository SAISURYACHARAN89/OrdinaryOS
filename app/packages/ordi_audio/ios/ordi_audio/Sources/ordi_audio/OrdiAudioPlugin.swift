import AVFoundation
import Flutter
import UIKit

/// Flutter's view of the audio engine.
///
/// Channel plumbing only. Everything realtime lives in `OrdiEngine`; Dart
/// receives state changes and a level to draw with, and nothing on the audio
/// path waits on it.
public class OrdiAudioPlugin: NSObject, FlutterPlugin {

  private let engine = OrdiEngine()
  private var eventSink: FlutterEventSink?

  private var lastState = OrdiEngine.State.idle
  private var lastLevel: Float = 0
  private var lastTranscript = ""

  /// Tool calls go over their own method channel rather than the event stream,
  /// because a tool call is a request that must receive a reply. The event
  /// stream is one-way, broadcast, and only attached after the permission
  /// prompt resolves — a tool call dropped there would freeze the conversation
  /// permanently, since the model generates nothing until it is answered.
  private var toolChannel: FlutterMethodChannel?

  /// Ids awaiting a reply from Dart, and ids the server has since withdrawn.
  /// Touched only from the main thread.
  private var pendingTools = Set<String>()
  private var cancelledTools = Set<String>()

  // MARK: - Registration

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = OrdiAudioPlugin()

    let methods = FlutterMethodChannel(
      name: "ordi/audio", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)

    let events = FlutterEventChannel(
      name: "ordi/audio/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)

    instance.toolChannel = FlutterMethodChannel(
      name: "ordi/audio/tools", binaryMessenger: registrar.messenger())

    instance.wire()
    instance.observeInterruptions()
  }

  private func wire() {
    engine.onState = { [weak self] state in
      guard let self else { return }
      self.lastState = state
      self.emit()
    }
    engine.onLevel = { [weak self] level in
      guard let self else { return }
      self.lastLevel = level
      self.emit()
    }
    engine.onTranscript = { [weak self] text in
      guard let self else { return }
      self.lastTranscript = text
      self.emit()
    }
    engine.onError = { [weak self] message in
      self?.emit(error: message)
    }
    engine.onExchangeComplete = { [weak self] question, answer in
      self?.emit(exchange: (question, answer))
    }
    engine.onResumptionHandle = { [weak self] handle in
      self?.emit(resumptionHandle: handle)
    }
    engine.onToolCall = { [weak self] calls in
      self?.dispatch(toolCalls: calls)
    }
    engine.onToolCancel = { [weak self] ids in
      guard let self else { return }
      // Withdrawn calls must not be answered. Whatever already ran, ran — a
      // placed call is not un-placed because the user interrupted.
      for id in ids where self.pendingTools.contains(id) {
        self.cancelledTools.insert(id)
        self.pendingTools.remove(id)
      }
    }
  }

  // MARK: - Tool bridge

  /// Hands each call to Dart and guarantees a reply goes back to the model.
  ///
  /// Function calling on this model is synchronous: from the moment a
  /// `toolCall` arrives the model generates nothing until it is answered. A
  /// missing reply is therefore not a lost feature but a dead conversation,
  /// and one the reconnect loop cannot detect — the socket stays perfectly
  /// healthy. Hence the watchdog: every call is answered, on time, whatever
  /// happens on the Dart side.
  private func dispatch(toolCalls: [GeminiLiveSession.ToolCall]) {
    for call in toolCalls {
      pendingTools.insert(call.id)

      guard let channel = toolChannel else {
        settle(call, ["error": "Tool channel unavailable."])
        continue
      }

      var replied = false
      let finish: ([String: Any]) -> Void = { [weak self] response in
        guard !replied else { return }
        replied = true
        self?.settle(call, response)
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        finish(["error": "Timed out."])
      }

      channel.invokeMethod(
        "invoke",
        arguments: ["id": call.id, "name": call.name, "args": call.args]
      ) { result in
        if let response = result as? [String: Any] {
          finish(response)
        } else if let error = result as? FlutterError {
          finish(["error": error.message ?? "Tool failed."])
        } else {
          // Includes FlutterMethodNotImplemented and a nil return.
          finish(["error": "Tool not handled."])
        }
      }
    }
  }

  private func settle(_ call: GeminiLiveSession.ToolCall, _ response: [String: Any]) {
    if cancelledTools.remove(call.id) != nil { return }
    guard pendingTools.remove(call.id) != nil else { return }
    engine.respond(toolResponses: [
      ["id": call.id, "name": call.name, "response": response]
    ])
  }

  // MARK: - Method channel

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermission":
      requestPermission { result($0) }

    case "start":
      do {
        try engine.start()
        result(true)
      } catch {
        result(FlutterError(
          code: "start_failed",
          message: "Could not start the audio engine: \(error.localizedDescription)",
          details: nil))
      }

    case "stop":
      engine.stop()
      result(nil)

    case "connect":
      guard
        let args = call.arguments as? [String: Any],
        let token = args["token"] as? String,
        let model = args["model"] as? String
      else {
        result(FlutterError(
          code: "bad_args", message: "connect needs a token and a model.", details: nil))
        return
      }
      engine.connect(token: token, model: model)
      result(nil)

    case "disconnect":
      engine.disconnect()
      result(nil)

    case "setRecording":
      let on = (call.arguments as? [String: Any])?["recording"] as? Bool ?? false
      engine.recordingMode = on
      result(nil)

    case "ask":
      guard let text = (call.arguments as? [String: Any])?["text"] as? String else {
        result(FlutterError(code: "bad_args", message: "ask needs text.", details: nil))
        return
      }
      engine.ask(text)
      result(nil)

    case "takePendingQuestion":
      // Set by the Siri intent before Flutter was running. Reading clears it.
      let defaults = UserDefaults.standard
      let key = "ordi.pendingQuestion"
      let text = defaults.string(forKey: key)
      let ranAt = defaults.double(forKey: "ordi.pendingQuestionAt")
      if text?.isEmpty == false { defaults.removeObject(forKey: key) }
      result([
        "text": text ?? "",
        // Non-zero means the Siri intent did run at some point, which is the
        // difference between "Siri never handed anything over" and "it did but
        // we read it too early".
        "intentRanAt": ranAt,
      ])

    case "isRunning":
      result(engine.isRunning)

    case "stats":
      result([
        "taps": engine.tapCount,
        "running": engine.isRunning,
        "hasSink": eventSink != nil,
        "state": lastState.rawValue,
        "vp": engine.voiceProcessing,
      ])

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestPermission(_ done: @escaping (Bool) -> Void) {
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission { granted in
        DispatchQueue.main.async { done(granted) }
      }
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async { done(granted) }
      }
    }
  }

  // MARK: - Event channel

  private func emit(
    error: String? = nil, wake: Bool = false,
    exchange: (question: String, answer: String)? = nil,
    resumptionHandle: String? = nil
  ) {
    guard let sink = eventSink else { return }
    var payload: [String: Any] = [
      "state": lastState.rawValue,
      "amplitude": Double(lastLevel),
      "transcript": lastTranscript,
    ]
    if let error { payload["error"] = error }
    if wake { payload["wake"] = true }
    // Present only on the rare frame where a turn just finished — every
    // other frame omits these two keys entirely rather than sending empty
    // strings, so Dart can tell "no exchange this frame" from "an empty one".
    if let exchange {
      payload["exchangeQuestion"] = exchange.question
      payload["exchangeAnswer"] = exchange.answer
    }
    // Same idea: only present on the frame a fresh handle actually arrived.
    if let resumptionHandle { payload["resumptionHandle"] = resumptionHandle }
    DispatchQueue.main.async { sink(payload) }
  }

  // MARK: - Interruptions

  /// Phone calls, Siri and route changes all tear the session down. Without
  /// this the app returns from a call with a dead microphone and no error.
  private func observeInterruptions() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification, object: nil)
  }

  @objc private func handleInterruption(_ note: Notification) {
    guard
      let info = note.userInfo,
      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }

    switch type {
    case .began:
      engine.stop()
    case .ended:
      let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
        AVAudioSession.InterruptionOptions(rawValue: $0)
      }
      if options?.contains(.shouldResume) == true {
        try? engine.start()
      }
    @unknown default:
      break
    }
  }

  @objc private func handleRouteChange(_ note: Notification) {
    guard
      let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
    else { return }

    // Unplugging headphones invalidates the engine's format. Rebuild rather
    // than limping on with a stale one.
    guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable,
          engine.isRunning else { return }
    engine.stop()
    try? engine.start()
  }
}

extension OrdiAudioPlugin: FlutterStreamHandler {
  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
