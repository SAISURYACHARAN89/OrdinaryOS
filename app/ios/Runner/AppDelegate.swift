import AVFoundation
import AppIntents
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Without this, a reminder that comes due while Ordi is frontmost is
    // dropped by iOS instead of shown — the plugin routes the callbacks but
    // does not claim the delegate itself. Only sets the delegate; asking for
    // permission stays lazy, on the first reminder, because a permission sheet
    // during launch collides with the microphone prompt and the foreground
    // wait the audio engine depends on.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Lets Study Mode move its speech from the earpiece to the loudspeaker.
    // Deliberately here rather than in the audio package: it changes nothing
    // about the audio session's category, mode or options, only which output
    // port the current route uses.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OrdiRoute") {
      let channel = FlutterMethodChannel(
        name: "ordi/route", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "preferSpeaker" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let session = AVAudioSession.sharedInstance()
        // Only when the sound really is going to the earpiece. With headphones,
        // AirPods or a car connected the person chose that route, and forcing
        // the speaker would override it.
        let onEarpiece = session.currentRoute.outputs.contains {
          $0.portType == .builtInReceiver
        }
        if onEarpiece {
          try? session.overrideOutputAudioPort(.speaker)
        }
        result(onEarpiece)
      }
    }
  }
}

// MARK: - Siri

/// Reaching Ordi when the app is closed.
///
/// iOS gives a third-party app no way to wake itself: the always-on listening
/// layer belongs to Siri, and an app that has been swiped away or has not been
/// launched since reboot cannot start itself for any reason. Our own wake word
/// can only run while the app is already alive.
///
/// This is the one path that does work from a locked, dark phone with Ordi
/// fully terminated — the user says "Hey Siri, talk to Ordi" and iOS launches
/// us. It is a hand-off rather than true always-on listening, and marketing
/// should never describe it as more than that.
///
/// Lives in this file deliberately: `AppShortcutsProvider` has to be compiled
/// into the app target, and Runner.xcodeproj does not use synchronized folders,
/// so a new file would mean hand-editing project.pbxproj. Move it out when the
/// project gets restructured.
@available(iOS 16.0, *)
struct TalkToOrdiIntent: AppIntent {
  static var title: LocalizedStringResource = "Talk to Ordi"
  static var description = IntentDescription(
    "Opens Ordi and starts listening straight away.")

  /// Ordi is a voice conversation, so there is nothing useful to do headlessly
  /// — bring the app forward and let the orb take over.
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult {
    return .result()
  }
}

@available(iOS 16.0, *)
struct OrdiShortcuts: AppShortcutsProvider {
  /// `.applicationName` resolves to "Ordi", so these become "Hey Siri, talk to
  /// Ordi", "Hey Siri, ask Ordi", and so on. Every phrase must contain the app
  /// name — iOS rejects the provider outright otherwise, and it fails at build
  /// time rather than silently.
  /// One intent, one behaviour: open Ordi and start listening.
  ///
  /// A parameterised version was tried so Siri could pass the question
  /// through. Two things killed it: App Shortcut phrases only interpolate
  /// AppEntity/AppEnum parameters and never free text, so "ask Ordi
  /// <anything>" is not expressible; and Siri's fallback prompt for the value
  /// is unreliable from the lock screen, which meant it sometimes captured a
  /// question and sometimes just opened the app. Predictably opening is better
  /// than unpredictably doing more.
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: TalkToOrdiIntent(),
      phrases: [
        "Ask \(.applicationName)",
        "Talk to \(.applicationName)",
        "Start \(.applicationName)",
        "Open \(.applicationName)",
      ],
      shortTitle: "Talk to Ordi",
      systemImageName: "waveform.circle"
    )
  }
}
