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

  // MARK: - Registration

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = OrdiAudioPlugin()

    let methods = FlutterMethodChannel(
      name: "ordi/audio", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)

    let events = FlutterEventChannel(
      name: "ordi/audio/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)

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

  private func emit(error: String? = nil) {
    guard let sink = eventSink else { return }
    var payload: [String: Any] = [
      "state": lastState.rawValue,
      "amplitude": Double(lastLevel),
      "transcript": lastTranscript,
    ]
    if let error { payload["error"] = error }
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
