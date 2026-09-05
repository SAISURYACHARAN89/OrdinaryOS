import AppIntents
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
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
