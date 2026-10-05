import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'ai_brief.dart';

/// Gets a reminder in front of the user at the moment it is due.
///
/// Two channels, because neither is sufficient alone. An iOS local
/// notification is the guarantee: the OS owns the schedule, so it fires
/// whether or not Ordi is running — but it can only show text and play a
/// system sound, it cannot speak. So when the app *is* alive and connected, a
/// timer beats the notification to it, cancels it, and has Ordi say the
/// reminder out loud instead.
///
/// The speaking half deliberately goes through Ordi's own Live session rather
/// than the on-device synthesiser that Study Mode uses. Voice processing
/// cancels the audio engine's output from the microphone; it knows nothing
/// about `AVSpeechSynthesizer`. Speaking a reminder that way would put it
/// straight back into the mic, where Ordi would hear it as the user talking,
/// barge in on itself, and answer it.
class ReminderScheduler {
  ReminderScheduler({required this.speak});

  /// Says something in Ordi's voice. Returns false if it couldn't — no
  /// session, app asleep — in which case the notification is left to fire.
  final Future<bool> Function(String text) speak;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// iOS keeps at most 64 pending local notifications and silently drops the
  /// rest, so the furthest-out reminders are the ones that don't get a slot.
  static const _maxScheduled = 60;

  /// Fired slightly early so Ordi speaks it rather than the banner arriving
  /// first and the two overlapping.
  static const _speakLead = Duration(seconds: 2);

  /// Called with the number when someone taps a "call" notification. Set by
  /// whoever places calls; this class only carries the tap back.
  void Function(String phone)? onCallTapped;

  final Map<int, Timer> _spoken = {};
  bool _ready = false;
  bool? _permitted;

  Future<void> _ensureReady() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation(await _localZoneName()));
    } catch (_) {
      // Falls back to UTC-as-local, which only matters if scheduling fails
      // outright; the spoken path is unaffected.
    }
    await _plugin.initialize(
      const InitializationSettings(
        // The white status-bar silhouette from the audio package; Android
        // draws small icons as a single-colour mask.
        android: AndroidInitializationSettings('ic_stat_ordinary'),
        iOS: DarwinInitializationSettings(
          // Asked for separately, and lazily — see [_permission].
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload ?? '';
        if (payload.startsWith(_callPrefix)) {
          onCallTapped?.call(payload.substring(_callPrefix.length));
        }
      },
    );
    _ready = true;
  }

  /// The IANA zone name for wherever the phone is. `timezone` needs a name;
  /// Dart only exposes an offset, so this matches on current offset.
  Future<String> _localZoneName() async {
    final offset = DateTime.now().timeZoneOffset;
    for (final name in tz.timeZoneDatabase.locations.keys) {
      final location = tz.timeZoneDatabase.locations[name]!;
      final now = tz.TZDateTime.now(location);
      if (now.timeZoneOffset == offset) return name;
    }
    return 'UTC';
  }

  /// Asked for the first time a reminder is actually scheduled, never at
  /// launch. A permission sheet during startup lands on top of the microphone
  /// prompt and the foreground wait the audio engine depends on, and the
  /// reliable result of that collision is a deaf app.
  /// Asks for notification permission now — used by first-launch setup, so
  /// the prompt appears with an explanation instead of mid-conversation.
  Future<bool> requestPermission() => _permission();

  Future<bool> _permission() async {
    final cached = _permitted;
    if (cached != null) return cached;
    bool granted;
    try {
      await _ensureReady();
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        // Android 13+ asks; older versions allow notifications by default.
        granted = await android.requestNotificationsPermission() ?? false;
      } else {
        granted = await _plugin
                .resolvePlatformSpecificImplementation<
                    IOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
    } catch (error) {
      // No notifications plugin (tests, or a failed start): treat as refused
      // for this run rather than letting setup or a tool call throw.
      debugPrint('[reminders] permission unavailable: $error');
      return false;
    }
    _permitted = granted;
    return granted;
  }

  /// Schedules one task. Safe to call again for the same task — the OS
  /// replaces a pending notification that reuses its id.
  Future<void> schedule(BriefTask task) async {
    final due = task.dueAt;
    if (due == null || task.done) return;
    if (!due.isAfter(DateTime.now())) return;

    _armSpoken(task, due);

    // Everything below is the OS-side safety net, and callers fire this
    // unawaited from inside a tool handler — so nothing here may throw. The
    // spoken path above is already armed and works without any of it.
    try {
      if (!await _permission()) return;
      await _ensureReady();
      await _plugin.zonedSchedule(
        task.id,
        'Ordinary',
        task.title,
        tz.TZDateTime.from(due, tz.local),
        const NotificationDetails(
          android: _reminderChannel,
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
        androidScheduleMode: await _androidScheduleMode(),
      );
    } catch (error) {
      debugPrint('[reminders] could not schedule: $error');
    }
  }

  static const _callPrefix = 'call:';

  static const _reminderChannel = AndroidNotificationDetails(
    'ordinary_reminders',
    'Reminders',
    channelDescription: 'Reminders you asked Ordinary to set.',
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.reminder,
  );

  static const _noticeChannel = AndroidNotificationDetails(
    'ordinary_notices',
    'Notices',
    channelDescription: 'Calls to place and recordings that stopped.',
    importance: Importance.high,
    priority: Priority.high,
  );

  /// Exact where Android allows it. Since Android 14 exact alarms need the
  /// user's say-so, and without it an exact request fails outright — so fall
  /// back to "about then" rather than not at all. While the app is alive the
  /// spoken reminder fires on time regardless.
  Future<AndroidScheduleMode> _androidScheduleMode() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return AndroidScheduleMode.exactAllowWhileIdle;
      final exact = await android.canScheduleExactNotifications() ?? false;
      return exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle;
    } catch (_) {
      return AndroidScheduleMode.inexactAllowWhileIdle;
    }
  }

  /// A notification that places a call when tapped.
  ///
  /// iOS will not open the dialler for an app that is in the background, and
  /// Ordi is usually in the background when someone says "call Charan" with
  /// the phone in a pocket. So the request becomes a banner instead: tapping it
  /// brings the app forward, where the call can be started. Returns false if
  /// notifications are not allowed, in which case there is nothing to show.
  Future<bool> showCallPrompt(String name, String phone) async {
    try {
      if (!await _permission()) return false;
      await _ensureReady();
      await _plugin.show(
        // Fixed: a second request replaces the first rather than stacking up.
        0x0ca11,
        'Call $name',
        'Tap to call',
        const NotificationDetails(
          android: _noticeChannel,
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
        payload: '$_callPrefix$phone',
      );
      return true;
    } catch (error) {
      debugPrint('[reminders] could not show call prompt: $error');
      return false;
    }
  }

  /// A one-off notice, such as a recording that stopped on its own. Silent
  /// if notifications are not allowed.
  Future<void> showNotice(String title, String body) async {
    try {
      if (!await _permission()) return;
      await _ensureReady();
      await _plugin.show(
        0x0ca12,
        title,
        body,
        const NotificationDetails(
          android: _noticeChannel,
          iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
        ),
      );
    } catch (error) {
      debugPrint('[reminders] could not show notice: $error');
    }
  }

  /// Re-arms everything still pending. Called at launch, since in-process
  /// timers don't survive the app being closed even though the OS-side
  /// notifications do.
  Future<void> restore(AiBrief brief) async {
    final pending = brief.upcoming.take(_maxScheduled);
    for (final task in pending) {
      _armSpoken(task, task.dueAt!);
    }
  }

  void _armSpoken(BriefTask task, DateTime due) {
    _spoken.remove(task.id)?.cancel();
    final wait = due.difference(DateTime.now()) - _speakLead;
    if (wait.isNegative) return;
    // Dart timers are milliseconds on a 64-bit int, so a reminder years out is
    // fine; it simply never fires because the app won't live that long. The
    // OS-side notification is what covers that case.
    _spoken[task.id] = Timer(wait, () async {
      _spoken.remove(task.id);
      // The marker is what the system instruction keys on to treat this as an
      // app message rather than something overheard — without it the wake gate
      // would decide nobody was addressing Ordi and swallow the reminder.
      var said = false;
      try {
        said = await speak('[ordi] remind: ${task.title}');
      } catch (_) {
        // Treated as "couldn't speak" — the notification covers it.
      }
      // Only pull the banner if Ordi actually said it out loud. If it
      // couldn't, the notification is the entire reminder.
      if (said) await cancel(task.id);
    });
  }

  Future<void> cancel(int id) async {
    _spoken.remove(id)?.cancel();
    try {
      // Set up first if this run hasn't scheduled anything yet. The OS keeps
      // notifications from earlier runs, and skipping this used to leave them
      // pending: a reminder deleted or ticked off after a relaunch still went
      // off. Setting up asks for no permission.
      await _ensureReady();
      await _plugin.cancel(id);
    } catch (_) {
      // Cancelling something that already fired is not a failure.
    }
  }

  void dispose() {
    for (final timer in _spoken.values) {
      timer.cancel();
    }
    _spoken.clear();
  }
}
