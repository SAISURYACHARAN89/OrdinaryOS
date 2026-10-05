import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' hide Account;
import 'package:ordi_audio/ordi_audio.dart' show OrdiAudio, OrdiState;
import 'package:url_launcher/url_launcher.dart';

import '../history/history_screen.dart';
import '../main.dart';
import '../models/account.dart';
import '../models/ai_brief.dart';
import '../models/device.dart';
import '../models/ordi_settings.dart';
import '../models/pairing.dart';
import '../models/recording_store.dart';
import '../models/speed_dial.dart';
import '../models/study.dart';
import '../recordings/recordings_screen.dart';
import '../settings/settings_screen.dart';
import '../ui/time_format.dart';
import 'reminder_editor.dart';
import '../ordi/ordi_controller.dart';
import '../ordi/ordi_screen.dart';
import '../study/study_screen.dart';
import '../ui/device_icons.dart';
import '../ui/surface.dart';
import '../ui/tokens.dart';

/// The dashboard.
///
/// Follows the hand sketch: identity and balance at the top, the two products
/// side by side, then the controls that act on them, then the things you
/// actually do — study, talk, review. Tasks Ordi extracted sit at the bottom,
/// where a glance finds them without any navigation. Restyled to the
/// Terracotta Field system: flat grey cards on white, ink-black actions.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Owned at the app root, like the stores below, so Ordi can open study
  /// mode by voice from any screen.
  late Devices _devices;
  late StudyLibrary _study;
  bool _haveDevices = false;
  Pairing? _pairing;
  OrdiSettings? _settings;

  /// All owned at the app root (`main.dart`), not here — each has to keep
  /// working whether or not the dashboard is the screen currently showing:
  /// tasks keep arriving from finished conversations, a recording keeps
  /// capturing, and Ordi has to be able to voice-dial speed dial from
  /// anywhere. Picked up in [didChangeDependencies], since reaching them needs
  /// a `BuildContext`.
  AiBrief? _brief;
  SpeedDial? _speedDial;
  RecordingStore? _recordings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final devices = OrdiScope.devicesOf(context);
    if (!_haveDevices || _devices != devices) {
      if (_haveDevices) _devices.removeListener(_onDevices);
      _pairing?.removeListener(_onDevices);
      _settings?.removeListener(_onDevices);
      _devices = devices..addListener(_onDevices);
      _haveDevices = true;
    }
    _study = OrdiScope.studyOf(context);

    final settings = OrdiScope.settingsOf(context);
    if (_settings != settings) {
      _settings?.removeListener(_onDevices);
      _settings = settings..addListener(_onDevices);
    }

    final pairing = OrdiScope.pairingOf(context);
    if (_pairing != pairing) {
      _pairing?.removeListener(_onDevices);
      _pairing = pairing..addListener(_onDevices);
    }

    final brief = OrdiScope.briefOf(context);
    if (_brief != brief) {
      _brief?.removeListener(_onDevices);
      _brief = brief..addListener(_onDevices);
    }

    final speedDial = OrdiScope.speedDialOf(context);
    if (_speedDial != speedDial) {
      _speedDial?.removeListener(_onDevices);
      _speedDial = speedDial..addListener(_onDevices);
    }

    final recordings = OrdiScope.recordingsOf(context);
    if (_recordings != recordings) {
      _recordings?.removeListener(_onDevices);
      _recordings = recordings..addListener(_onDevices);
    }
  }

  @override
  void dispose() {
    if (_haveDevices) _devices.removeListener(_onDevices);
    _brief?.removeListener(_onDevices);
    _speedDial?.removeListener(_onDevices);
    _recordings?.removeListener(_onDevices);
    super.dispose();
  }

  void _onDevices() => setState(() {});

  void _openOrdi(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OrdiScreen(controller: OrdiScope.of(context)),
      ),
    );
  }

  void _openStudyMode(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => StudyScreen(library: _study)));
  }

  /// Reopens setup to pair a device.
  void _openSetup() {
    final pairing = _pairing;
    if (pairing == null) return;
    if (!pairing.wantsBand) pairing.choose(PairingSetup.audiosAndBand);
    pairing.restart();
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: OrdiScope.settingsOf(context),
          controller: OrdiScope.of(context),
          recordings: OrdiScope.recordingsOf(context),
          pairing: OrdiScope.pairingOf(context),
          account: OrdiScope.accountOf(context),
        ),
      ),
    );
  }

  void _openRecordings(BuildContext context) {
    OrdiScope.recordingsOf(context).retryMissingSummaries();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            RecordingsScreen(store: OrdiScope.recordingsOf(context)),
      ),
    );
  }

  void _openHistory(BuildContext context) {
    final log = OrdiScope.logOf(context);
    // Catches the current conversation if it's gone quiet long enough to
    // count as finished but nothing has started a new one to close it yet —
    // otherwise the most recent session could sit untitled indefinitely.
    log.finalizeIfIdle();
    log.retryMissingTitles();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => HistoryScreen(log: log)));
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold matters beyond providing a screen frame: it wraps its content
    // in a Material widget, which supplies a real DefaultTextStyle. Without
    // one, every Text falls back to Flutter's loud double-yellow-underline
    // default, in release builds too.
    final pairing = _pairing;
    final wantsBand = pairing?.wantsBand ?? true;
    final bandSelected = wantsBand && _devices.selected == OrdinaryDevice.band;
    final conversate = _ActionTile(
      title: 'Conversate',
      icon: Icons.graphic_eq_rounded,
      onTap: () => _openOrdi(context),
      // History lives in the corner of Conversate, a tap away from the thing
      // it is a record of.
      trailingIcon: Icons.history_rounded,
      onTrailingTap: () => _openHistory(context),
    );

    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              Tokens.gutter,
              Tokens.x2,
              Tokens.gutter,
              Tokens.x10,
            ),
            children: [
              _TopBar(
                account: OrdiScope.accountOf(context),
                initial: OrdiScope.settingsOf(context).initial,
                onProfile: () => _openSettings(context),
              ),
              const SizedBox(height: Tokens.x2),
              // Whether Ordi can hear you right now. A deaf Ordi used to look
              // exactly like a working one.
              _OrdiStatus(controller: OrdiScope.of(context)),
              const SizedBox(height: Tokens.x4),

              // The two products, given equal weight — neither is the accessory.
              // Real Bluetooth state from pairing; an unpaired card opens setup.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _DeviceCard(
                        device: OrdinaryDevice.glasses,
                        paired: pairing?.audiosId != null,
                        connected: pairing?.audiosConnected ?? false,
                        battery: pairing?.audiosBattery ?? -1,
                        onPair: _openSetup,
                      ),
                    ),
                    const SizedBox(width: Tokens.x3),
                    Expanded(
                      child: _DeviceCard(
                        device: OrdinaryDevice.band,
                        paired: pairing?.bandId != null,
                        connected: pairing?.bandConnected ?? false,
                        battery: pairing?.bandBattery ?? -1,
                        onPair: _openSetup,
                        addLabel: wantsBand ? null : 'Add a Band',
                      ),
                    ),
                  ],
                ),
              ),

              // Where Ordi runs. Only a choice for someone with a Band.
              if (wantsBand) ...[
                const _SectionLabel('Selected device'),
                _ControlRow(
                  devices: _devices,
                  bandConnected: pairing?.bandConnected ?? false,
                ),
              ],

              _SpeedDialRow(speedDial: _speedDial),

              // Only present while something is being captured. Recording is
              // started by voice and Ordi goes quiet when it is, so without
              // this there is nothing on screen saying it is still running —
              // and an unnoticed recording is the expensive kind.
              if (_recordings?.isRecording ?? false) ...[
                const SizedBox(height: Tokens.x5),
                _RecordingBanner(store: _recordings!),
              ],

              const _SectionLabel('Do things'),
              // Study Mode is where notes are set up to sync to the Band, so it
              // is only offered with the Band selected. With the Band: Study
              // Mode and Conversate side by side, Recordings full width below.
              // With the phone: Conversate and Recordings side by side.
              // IntrinsicHeight keeps paired tiles the same height.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: bandSelected
                          ? _ActionTile(
                              title: 'Study Mode',
                              icon: Icons.menu_book_outlined,
                              onTap: () => _openStudyMode(context),
                            )
                          : conversate,
                    ),
                    const SizedBox(width: Tokens.x3),
                    Expanded(
                      child: bandSelected
                          ? conversate
                          : _ActionTile(
                              title: 'Recordings',
                              icon: Icons.radio_button_unchecked_rounded,
                              onTap: () => _openRecordings(context),
                            ),
                    ),
                  ],
                ),
              ),
              if (bandSelected) ...[
                const SizedBox(height: Tokens.x3),
                _WideAction(
                  title: 'Recordings',
                  icon: Icons.radio_button_unchecked_rounded,
                  onTap: () => _openRecordings(context),
                ),
              ],

              const _SectionLabel('Tasks'),
              _TaskList(
                tasks: _brief?.tasks ?? const [],
                onToggle: (task) => _brief?.toggleTask(task),
                onEdit: (task) {
                  final brief = _brief;
                  if (brief != null) {
                    showReminderEditor(context, brief: brief, task: task);
                  }
                },
                onDelete: (task) {
                  final brief = _brief;
                  if (brief == null) return;
                  final at = brief.tasks.indexOf(task);
                  brief.remove(task);
                  final messenger = ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar();
                  messenger.showSnackBar(SnackBar(
                    content: Text('Deleted "${task.title}"',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    behavior: SnackBarBehavior.floating,
                    backgroundColor: Tokens.text,
                    duration: const Duration(seconds: 4),
                    action: SnackBarAction(
                      label: 'Undo',
                      textColor: Tokens.accentInk,
                      onPressed: () => brief.restore(task, at: at),
                    ),
                  ));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One quiet line under the top bar: listening, connecting, or — when the
/// microphone is refused — a tap straight to iOS Settings.
class _OrdiStatus extends StatelessWidget {
  const _OrdiStatus({required this.controller});

  final OrdiController controller;

  Future<void> _openSettings() async {
    try {
      if (Platform.isAndroid) {
        await OrdiAudio.openAppSettings();
      } else {
        await launchUrl(Uri.parse('app-settings:'));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([controller, controller.reading]),
      builder: (context, _) {
        final (Color dot, String text, bool fix) = controller.micDenied
            ? (Tokens.danger, 'Microphone off — tap to turn it on', true)
            : controller.problem != null
            ? (Tokens.danger, controller.problem!.split('\n').first, false)
            : !controller.connected
            ? (Tokens.textFaint, 'Connecting to Ordinary…', false)
            : switch (controller.reading.value.state) {
                OrdiState.speaking => (
                  Tokens.connected,
                  'Ordinary is speaking',
                  false,
                ),
                OrdiState.thinking => (Tokens.connected, 'Thinking…', false),
                OrdiState.listening => (Tokens.connected, 'Listening…', false),
                OrdiState.idle => (
                  Tokens.connected,
                  'Listening for "Hey Ordinary"',
                  false,
                ),
              };
        final row = Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
            ),
            const SizedBox(width: Tokens.x2),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Tokens.caption.copyWith(
                  fontSize: 13,
                  color: fix ? Tokens.danger : Tokens.textSoft,
                ),
              ),
            ),
            if (fix)
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: Tokens.danger,
              ),
          ],
        );
        return Semantics(
          liveRegion: true,
          button: fix,
          child: fix
              ? GestureDetector(
                  onTap: _openSettings,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Tokens.x2),
                    child: row,
                  ),
                )
              : row,
        );
      },
    );
  }
}

/// A small upper-case caption above a block. The gap above it is what
/// separates the blocks — there are no dividers.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Tokens.x6, bottom: Tokens.x3),
      child: Text(text.toUpperCase(), style: Tokens.label),
    );
  }
}

// ------------------------------------------------------------------ top bar

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.account,
    required this.initial,
    required this.onProfile,
  });

  final Account account;
  final String initial;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text.rich(
          TextSpan(
            text: 'Ordinary',
            children: [
              TextSpan(
                text: ' OS',
                style: TextStyle(
                  color: Tokens.textFaint,
                  fontWeight: FontWeight.w500,
                  fontVariations: const [FontVariation('wght', 500)],
                ),
              ),
            ],
          ),
          style: Tokens.title.copyWith(fontSize: 26),
        ),
        const Spacer(),
        // Today's allowance, live: it counts down as Ordinary answers.
        AnimatedBuilder(
          animation: account,
          builder: (context, _) {
            final label = creditsLabel(account.credits);
            return Semantics(
              button: true,
              label: '$label. Open settings',
              excludeSemantics: true,
              child: GestureDetector(
                onTap: onProfile,
                child: _CreditsPill(label: label),
              ),
            );
          },
        ),
        const SizedBox(width: Tokens.x3),
        // Profile — opens Settings. Solid ink until there are accounts.
        Semantics(
          button: true,
          label: 'Profile and settings',
          excludeSemantics: true,
          child: GestureDetector(
            onTap: onProfile,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Tokens.text,
              ),
              alignment: Alignment.center,
              child: Text(
                initial,
                style: Tokens.heading.copyWith(
                  color: Tokens.accentInk,
                  fontSize: 16,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The credits balance as a quiet number in a grey pill. No icon for now.
class _CreditsPill extends StatelessWidget {
  const _CreditsPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Tokens.x3, vertical: 7),
      decoration: BoxDecoration(
        color: Tokens.paper2,
        borderRadius: BorderRadius.circular(Tokens.rPill),
      ),
      child: Text(
        label,
        style: Tokens.bodyStrong.copyWith(
          fontSize: 13,
          color: Tokens.textSoft,
          height: 1.2,
        ),
      ),
    );
  }
}

/// "18 left", "Unlimited", or a dash before the first count arrives.
String creditsLabel(Credits? credits) {
  if (credits == null) return '—';
  if (credits.unlimited) return 'Unlimited';
  return '${credits.left ?? credits.dailyLimit ?? 0} left';
}

// -------------------------------------------------------------- device card

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.paired,
    required this.connected,
    required this.battery,
    required this.onPair,
    this.addLabel,
  });

  final OrdinaryDevice device;
  final bool paired;
  final bool connected;

  /// 0..100, or -1 when the device does not report one.
  final int battery;
  final VoidCallback onPair;

  /// Set when this device is not part of the setup at all (Audios alone): the
  /// card becomes an invitation to add it.
  final String? addLabel;

  @override
  Widget build(BuildContext context) {
    final Widget status;
    if (addLabel != null) {
      status = Text(
        addLabel!,
        style: Tokens.bodyStrong.copyWith(fontSize: 15, color: Tokens.textSoft),
      );
    } else if (!paired) {
      status = Text(
        'Tap to pair',
        style: Tokens.bodyStrong.copyWith(fontSize: 15, color: Tokens.textSoft),
      );
    } else if (connected && battery >= 0) {
      status = Text('$battery%', style: Tokens.numeral.copyWith(fontSize: 22));
    } else {
      // Battery only while connected; otherwise say so instead of a stale
      // number.
      status = Text(
        connected ? 'Connected' : 'Not connected',
        style: Tokens.bodyStrong.copyWith(
          fontSize: 15,
          color: connected ? Tokens.text : Tokens.textFaint,
        ),
      );
    }

    return Surface(
      radius: Tokens.rMedium,
      onTap: paired && addLabel == null ? null : onPair,
      padding: const EdgeInsets.all(Tokens.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusDot(connected: connected),
              const SizedBox(width: 6),
              Text(device.label.toUpperCase(), style: Tokens.label),
            ],
          ),
          const SizedBox(height: Tokens.x3),
          // The product itself: bright while connected, dim otherwise.
          AnimatedOpacity(
            opacity: connected ? 1 : 0.28,
            duration: const Duration(milliseconds: 300),
            child: SizedBox(
              height: 96,
              width: double.infinity,
              child: Image.asset(
                device == OrdinaryDevice.band
                    ? 'assets/devices/band.png'
                    : 'assets/devices/glasses.png',
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                excludeFromSemantics: true,
              ),
            ),
          ),
          const SizedBox(height: Tokens.x3),
          status,
        ],
      ),
    );
  }
}

/// The connected indicator: a small filled dot — green when live, grey when not.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: connected ? Tokens.connected : Tokens.textFaint,
      ),
    );
  }
}

// ------------------------------------------------------------- control row

/// Device selector plus sync: a pill track where the active device is a solid
/// ink pill, and a round sync button beside it. The status of the last sync
/// sits underneath.
class _ControlRow extends StatelessWidget {
  const _ControlRow({required this.devices, required this.bandConnected});

  final Devices devices;

  /// Syncing needs the Band itself. It used to pretend, and report "Synced
  /// just now" with no Band paired at all.
  final bool bandConnected;

  @override
  Widget build(BuildContext context) {
    final band = devices.selected == OrdinaryDevice.band;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _Segmented(
                labels: [
                  for (final device in OrdinaryDevice.computeTargets)
                    device.label,
                ],
                selectedIndex: OrdinaryDevice.computeTargets.indexOf(
                  devices.selected,
                ),
                onSelected: (index) =>
                    devices.select(OrdinaryDevice.computeTargets[index]),
              ),
            ),
            // Syncing sends study notes and contacts to the Band; there is
            // nothing to sync to the phone that is already running the app.
            if (band) ...[
              const SizedBox(width: Tokens.x3),
              Opacity(
                opacity: bandConnected ? 1 : 0.4,
                child: IgnorePointer(
                  ignoring: !bandConnected,
                  child: _SyncButton(devices: devices),
                ),
              ),
            ],
          ],
        ),
        if (band) ...[
          const SizedBox(height: Tokens.x3),
          Text(
            bandConnected
                ? devices.syncLabel
                : 'Ordinary runs on your phone until your Band is connected.',
            style: Tokens.caption,
          ),
        ],
      ],
    );
  }
}

/// A two-or-more-way pill selector whose active thumb slides.
class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const double _height = 44;
  static const double _pad = 3;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _height,
      padding: const EdgeInsets.all(_pad),
      decoration: BoxDecoration(
        color: Tokens.paper2,
        borderRadius: BorderRadius.circular(Tokens.rPill),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final count = labels.length;
          final thumbWidth = constraints.maxWidth / count;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                left: thumbWidth * selectedIndex,
                top: 0,
                bottom: 0,
                width: thumbWidth,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Tokens.text,
                    borderRadius: BorderRadius.all(
                      Radius.circular(Tokens.rPill),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < count; i++)
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: i == selectedIndex,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onSelected(i),
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 220),
                              style: Tokens.bodyStrong.copyWith(
                                fontSize: 14,
                                color: i == selectedIndex
                                    ? Tokens.accentInk
                                    : Tokens.textSoft,
                              ),
                              child: Text(labels[i]),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Sends notes and contacts to the Band. A labelled pill with an upload
/// arrow — a bare circular-arrows icon read as "refresh".
class _SyncButton extends StatelessWidget {
  const _SyncButton({required this.devices});

  final Devices devices;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Sync notes and contacts to your Band',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: devices.syncing ? null : devices.sync,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: Tokens.x4),
          decoration: BoxDecoration(
            color: Tokens.paper2,
            borderRadius: BorderRadius.circular(Tokens.rPill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              devices.syncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Tokens.text),
                      ),
                    )
                  : const Icon(
                      Icons.file_upload_outlined,
                      color: Tokens.text,
                      size: 18,
                    ),
              const SizedBox(width: 6),
              Text(
                devices.syncing ? 'Syncing' : 'Sync',
                style: Tokens.bodyStrong.copyWith(fontSize: 14, height: 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- speed dial row

/// Contacts Ordi and the Band can call. Picking uses the system's own contact
/// picker (`CNContactPickerViewController` under the hood), which iOS treats
/// as permissionless — the user is choosing from a system UI, not handing the
/// app blanket read access to their address book.
///
/// Folded, it is a row of circles with first names under them; tapping the
/// section heading opens it into a list with each full name and number, a call
/// button and a remove button.
class _SpeedDialRow extends StatefulWidget {
  const _SpeedDialRow({required this.speedDial});

  /// Null for the one frame before [didChangeDependencies] has resolved it out
  /// of the scope.
  final SpeedDial? speedDial;

  @override
  State<_SpeedDialRow> createState() => _SpeedDialRowState();
}

class _SpeedDialRowState extends State<_SpeedDialRow> {
  bool _open = false;

  Future<void> _addContact() async {
    final store = widget.speedDial;
    if (store == null) return;
    Contact? picked;
    try {
      picked = await FlutterContacts.native.showPicker(
        properties: {ContactProperty.phone},
      );
    } catch (_) {
      return;
    }
    if (picked == null || picked.phones.isEmpty) return;
    store.add(
      SpeedDialContact(
        name: picked.displayName ?? 'Unknown',
        phone: picked.phones.first.number,
      ),
    );
  }

  Future<void> _call(SpeedDialContact contact) async {
    try {
      await launchUrl(Uri.parse('tel:${contact.dialNumber}'));
    } catch (_) {
      // Nothing sensible to show the user here — the dialer either opens or
      // it doesn't, and a failure means there's no dialer to fall back to.
    }
  }

  void _remove(SpeedDialContact contact) {
    final store = widget.speedDial;
    if (store == null) return;
    final index = store.contacts.indexOf(contact);
    if (index >= 0) store.removeAt(index);
  }

  @override
  Widget build(BuildContext context) {
    final contacts = widget.speedDial?.contacts ?? const <SpeedDialContact>[];
    final canOpen = contacts.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: canOpen ? () => setState(() => _open = !_open) : null,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.only(top: Tokens.x6, bottom: Tokens.x3),
            child: Row(
              children: [
                Text('SPEED DIAL', style: Tokens.label),
                const Spacer(),
                if (canOpen) ...[
                  Text(
                    _open ? 'Hide' : 'Show all',
                    style: Tokens.label.copyWith(color: Tokens.textSoft),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: const Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: Tokens.textSoft,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open && canOpen ? _expanded(contacts) : _folded(contacts),
        ),
      ],
    );
  }

  Widget _folded(List<SpeedDialContact> contacts) {
    return Wrap(
      spacing: Tokens.x4,
      runSpacing: Tokens.x3,
      children: [
        for (final contact in contacts)
          _Chip(
            label: contact.initial,
            semanticLabel: 'Call ${contact.name}',
            caption: contact.name.trim().split(RegExp(r'\s+')).first,
            onTap: () => _call(contact),
            onLongPress: () => setState(() => _open = true),
          ),
        _Chip(
          icon: Icons.add_rounded,
          filled: true,
          caption: 'Add',
          semanticLabel: 'Add a contact to speed dial',
          onTap: _addContact,
        ),
      ],
    );
  }

  Widget _expanded(List<SpeedDialContact> contacts) {
    return Surface(
      radius: Tokens.rMedium,
      padding: const EdgeInsets.symmetric(vertical: Tokens.x2),
      child: Column(
        children: [
          for (final contact in contacts)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tokens.x4,
                Tokens.x2,
                Tokens.x2,
                Tokens.x2,
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Tokens.paper,
                    ),
                    child: Text(
                      contact.initial,
                      style: Tokens.bodyStrong.copyWith(height: 1),
                    ),
                  ),
                  const SizedBox(width: Tokens.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          contact.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Tokens.heading.copyWith(fontSize: 16),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          contact.phone.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Tokens.caption.copyWith(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  RoundIconButton(
                    icon: Icons.call_rounded,
                    filled: true,
                    size: 36,
                    tooltip: 'Call ${contact.name}',
                    onTap: () => _call(contact),
                  ),
                  IconButton(
                    tooltip: 'Remove ${contact.name}',
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: Tokens.textFaint,
                    ),
                    onPressed: () => _remove(contact),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tokens.x4,
              Tokens.x2,
              Tokens.x4,
              Tokens.x2,
            ),
            child: GestureDetector(
              onTap: _addContact,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  const RoundIconButton(
                    icon: Icons.add_rounded,
                    filled: true,
                    size: 38,
                    onTap: null,
                  ),
                  const SizedBox(width: Tokens.x3),
                  Text('Add a contact', style: Tokens.bodyStrong),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A 34px circle — a contact's initial, or the black "+" — with a short
/// caption underneath.
class _Chip extends StatelessWidget {
  const _Chip({
    this.label,
    this.icon,
    this.caption,
    this.filled = false,
    required this.onTap,
    this.onLongPress,
    this.semanticLabel,
  });

  /// What VoiceOver says — "Call Charan", "Add a contact".
  final String? semanticLabel;
  final String? label;
  final IconData? icon;
  final String? caption;
  final bool filled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 48,
          child: Column(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? Tokens.text : Tokens.paper2,
                ),
                child: icon != null
                    ? Icon(icon, size: 18, color: Tokens.accentInk)
                    : Text(
                        label ?? '',
                        style: Tokens.bodyStrong.copyWith(
                          fontSize: 13,
                          height: 1,
                        ),
                      ),
              ),
              if (caption != null) ...[
                const SizedBox(height: 4),
                Text(
                  caption!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Tokens.caption.copyWith(fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- action cards

/// The compact half-width tile: an icon badge over the title.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.title,
    required this.icon,
    required this.onTap,
    this.trailingIcon,
    this.onTrailingTap,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;

  /// A small secondary destination in the corner — Conversate uses this for
  /// History.
  final IconData? trailingIcon;
  final VoidCallback? onTrailingTap;

  @override
  Widget build(BuildContext context) {
    final card = Surface(
      radius: Tokens.rMedium,
      onTap: onTap,
      padding: const EdgeInsets.all(Tokens.x4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconBadge(icon: icon),
          const SizedBox(height: Tokens.x3),
          Text(title, style: Tokens.heading.copyWith(fontSize: 17)),
        ],
      ),
    );

    if (trailingIcon == null) return card;

    // A sibling layered above the card rather than a child of it, so this
    // button gets first claim on taps in its own small area and everything
    // else falls through to the card underneath.
    return Stack(
      fit: StackFit.expand,
      children: [
        card,
        // The button's own 44-point tap area is centred on the visible 30-point
        // circle, so this keeps the circle 14 points in from the corner.
        Positioned(
          top: 7,
          right: 7,
          child: RoundIconButton(
            icon: trailingIcon!,
            onTap: onTrailingTap,
            size: 30,
            iconSize: 15,
            onPaper2: true,
            iconColor: Tokens.textFaint,
            tooltip: 'History',
          ),
        ),
      ],
    );
  }
}

/// The wide bottom row: badge, title, chevron.
class _WideAction extends StatelessWidget {
  const _WideAction({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Surface(
      radius: Tokens.rMedium,
      onTap: onTap,
      padding: const EdgeInsets.all(Tokens.x4 + 2),
      child: Row(
        children: [
          _IconBadge(icon: icon, size: 44),
          const SizedBox(width: Tokens.x4),
          Expanded(
            child: Text(title, style: Tokens.heading.copyWith(fontSize: 18)),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            color: Tokens.textFaint,
            size: 22,
          ),
        ],
      ),
    );
  }
}

/// A white rounded square with an ink glyph, sitting on a grey card.
class _IconBadge extends StatelessWidget {
  const _IconBadge({required this.icon, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Tokens.paper,
        borderRadius: BorderRadius.circular(Tokens.rBadge),
      ),
      child: Icon(icon, color: Tokens.text, size: size * 0.5),
    );
  }
}

// ---------------------------------------------------------- recording banner

/// Shown only while something is being captured.
///
/// Recording is started by voice and Ordi deliberately goes quiet for the
/// duration, so without this the app looks idle while it is in fact holding a
/// billed session open. The stop control is here because the voice route
/// ("Hey Ordi, stop recording") is exactly the thing that won't work if the
/// room is loud or the model has drifted.
class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner({required this.store});

  final RecordingStore store;

  @override
  Widget build(BuildContext context) {
    final recording = store.active;
    final label = recording?.label;
    final count = recording?.utterances.length ?? 0;

    return Surface(
      radius: Tokens.rMedium,
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.x4,
        vertical: Tokens.x3 + 2,
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Tokens.danger,
            ),
          ),
          const SizedBox(width: Tokens.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label == null ? 'Recording' : 'Recording — $label',
                  style: Tokens.heading.copyWith(fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  count == 0
                      ? 'Capturing everything said.'
                      : '$count captured so far.',
                  style: Tokens.caption,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: store.stop,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Tokens.x3,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                color: Tokens.paper,
                borderRadius: BorderRadius.circular(Tokens.rPill),
              ),
              child: Text(
                'Stop',
                style: Tokens.bodyStrong.copyWith(
                  fontSize: 13,
                  color: Tokens.danger,
                  height: 1.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- task list

/// What Ordi pulled out of your conversations.
///
/// Sits bare on the page rather than in a card: these are the one thing on
/// the screen you act on rather than navigate into, and boxing them would make
/// them read as another destination.
///
/// Real content — each of these came from `AiBrief.addExtracted` (or a spoken
/// reminder). An empty list means nothing has surfaced a task yet.
class _TaskList extends StatelessWidget {
  const _TaskList({
    required this.tasks,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final List<BriefTask> tasks;
  final ValueChanged<BriefTask> onToggle;
  final ValueChanged<BriefTask> onEdit;
  final ValueChanged<BriefTask> onDelete;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return Text(
        "Nothing yet — Ordinary will pull tasks out of your conversations "
        'as you go.',
        style: Tokens.body.copyWith(color: Tokens.textFaint),
      );
    }
    // AnimatedSize so a task leaving the list — ten seconds after it is ticked
    // off or has gone off — closes the gap smoothly instead of jumping.
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < tasks.length; i++)
            Padding(
              key: ValueKey(tasks[i].id),
              padding: EdgeInsets.only(
                bottom: i == tasks.length - 1 ? 0 : Tokens.x3,
              ),
              child: Dismissible(
                key: ValueKey('task-${tasks[i].id}'),
                direction: DismissDirection.endToStart,
                onDismissed: (_) => onDelete(tasks[i]),
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: Tokens.x4),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    color: Tokens.danger,
                  ),
                ),
                child: _TaskRow(
                  task: tasks[i],
                  onToggle: () => onToggle(tasks[i]),
                  onEdit: () => onEdit(tasks[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One task: the circle ticks it off, a tap anywhere else edits it, and a
/// swipe to the left deletes it.
class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.onToggle,
    required this.onEdit,
  });

  final BriefTask task;
  final VoidCallback onToggle;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      opacity: task.done ? 0.55 : 1,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            checked: task.done,
            label: task.done
                ? 'Done: ${task.title}'
                : 'Mark ${task.title} done',
            excludeSemantics: true,
            child: GestureDetector(
              onTap: onToggle,
              behavior: HitTestBehavior.opaque,
              // A 44-point target around a 22-point circle.
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 2, 14, 20),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: task.done ? Tokens.text : Colors.transparent,
                    border: Border.all(
                      color: task.done ? Tokens.text : Tokens.textFaint,
                      width: 1.8,
                    ),
                  ),
                  child: task.done
                      ? const Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: Tokens.accentInk,
                        )
                      : null,
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: onEdit,
              behavior: HitTestBehavior.opaque,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          style: Tokens.heading.copyWith(
                            fontSize: 17,
                            color: task.done ? Tokens.textFaint : Tokens.text,
                            decoration: task.done
                                ? TextDecoration.lineThrough
                                : null,
                            decorationColor: Tokens.textFaint,
                          ),
                        ),
                        // Only reminders asked for out loud, or given a time
                        // here, have one; scraped tasks don't pretend to.
                        if (task.dueAt != null && !task.done) ...[
                          const SizedBox(height: 2),
                          Text(
                            dueLabel(task.dueAt!),
                            style: Tokens.bodyStrong.copyWith(
                              fontSize: 13,
                              color: Tokens.textSoft,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
