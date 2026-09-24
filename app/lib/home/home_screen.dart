import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:ordi_audio/ordi_audio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../history/history_screen.dart';
import '../main.dart';
import '../models/ai_brief.dart';
import '../models/device.dart';
import '../models/recording_store.dart';
import '../models/speed_dial.dart';
import '../models/study.dart';
import '../recordings/recordings_screen.dart';
import '../settings/settings_screen.dart';
import '../ui/time_format.dart';
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
  final Devices _devices = Devices();

  /// Owned here rather than by StudyScreen so notes survive leaving and
  /// returning to Study Mode within the same app run.
  final StudyLibrary _study = StudyLibrary();

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
  void initState() {
    super.initState();
    _devices.addListener(_onDevices);
    _devices.load();
    _study.load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

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
    _devices.removeListener(_onDevices);
    _devices.dispose();
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
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StudyScreen(library: _study)),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: OrdiScope.settingsOf(context),
          controller: OrdiScope.of(context),
          recordings: OrdiScope.recordingsOf(context),
        ),
      ),
    );
  }

  void _openRecordings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordingsScreen(store: OrdiScope.recordingsOf(context)),
      ),
    );
  }

  void _openHistory(BuildContext context) {
    final log = OrdiScope.logOf(context);
    // Catches the current conversation if it's gone quiet long enough to
    // count as finished but nothing has started a new one to close it yet —
    // otherwise the most recent session could sit untitled indefinitely.
    log.finalizeIfIdle();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HistoryScreen(log: log)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold matters beyond providing a screen frame: it wraps its content
    // in a Material widget, which supplies a real DefaultTextStyle. Without
    // one, every Text falls back to Flutter's loud double-yellow-underline
    // default, in release builds too.
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
              _TopBar(balance: 1350, onProfile: () => _openSettings(context)),
              const SizedBox(height: Tokens.x5),

              // The two products, given equal weight — neither is the accessory.
              Row(
                children: [
                  Expanded(child: _DeviceCard(state: _devices.audio)),
                  const SizedBox(width: Tokens.x3),
                  Expanded(child: _DeviceCard(state: _devices.band)),
                ],
              ),

              const _SectionLabel('Selected device'),
              _ControlRow(devices: _devices),

              const _SectionLabel('Speed dial'),
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
              // Two up, one down: Study Mode and Conversate side by side,
              // Recordings full width beneath. IntrinsicHeight keeps the two
              // tiles the same height even if a title wraps.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _ActionTile(
                        title: 'Study Mode',
                        icon: Icons.menu_book_outlined,
                        onTap: () => _openStudyMode(context),
                      ),
                    ),
                    const SizedBox(width: Tokens.x3),
                    Expanded(
                      child: _ActionTile(
                        title: 'Conversate',
                        icon: Icons.graphic_eq_rounded,
                        onTap: () => _openOrdi(context),
                        // History lives in the corner of Conversate, a tap
                        // away from the thing it is a record of.
                        trailingIcon: Icons.history_rounded,
                        onTrailingTap: () => _openHistory(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Tokens.x3),
              _WideAction(
                title: 'Recordings',
                icon: Icons.radio_button_unchecked_rounded,
                onTap: () => _openRecordings(context),
              ),

              const _SectionLabel('Tasks'),
              _TaskList(
                tasks: _brief?.tasks ?? const [],
                onToggle: (index) => _brief?.toggle(index),
              ),
            ],
          ),
        ),
      ),
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
  const _TopBar({required this.balance, required this.onProfile});

  final int balance;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('Ordinary', style: Tokens.title.copyWith(fontSize: 26)),
        const Spacer(),
        _CreditsPill(balance: balance),
        const SizedBox(width: Tokens.x3),
        // Profile — opens Settings. Solid ink until there are accounts.
        GestureDetector(
          onTap: onProfile,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 34,
            height: 34,
            decoration:
                const BoxDecoration(shape: BoxShape.circle, color: Tokens.text),
            alignment: Alignment.center,
            child: Text(
              'O',
              style: Tokens.heading
                  .copyWith(color: Tokens.accentInk, fontSize: 16, height: 1),
            ),
          ),
        ),
      ],
    );
  }
}

/// The credits balance as a quiet number in a grey pill. No icon for now.
class _CreditsPill extends StatelessWidget {
  const _CreditsPill({required this.balance});

  final int balance;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Tokens.x3, vertical: 7),
      decoration: BoxDecoration(
        color: Tokens.paper2,
        borderRadius: BorderRadius.circular(Tokens.rPill),
      ),
      child: Text(
        _grouped(balance),
        style: Tokens.bodyStrong
            .copyWith(fontSize: 13, color: Tokens.textSoft, height: 1.2),
      ),
    );
  }

  static String _grouped(int n) {
    final digits = n.toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}

// -------------------------------------------------------------- device card

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.state});

  final DeviceState state;

  @override
  Widget build(BuildContext context) {
    return Surface(
      radius: Tokens.rMedium,
      padding: const EdgeInsets.all(Tokens.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusDot(connected: state.connected),
              const SizedBox(width: 6),
              Text(state.device.label.toUpperCase(), style: Tokens.label),
            ],
          ),
          const SizedBox(height: Tokens.x4),
          DeviceGlyph(device: state.device, size: 60, color: Tokens.text),
          const SizedBox(height: Tokens.x4),
          Text(state.batteryLabel, style: Tokens.numeral.copyWith(fontSize: 22)),
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
  const _ControlRow({required this.devices});

  final Devices devices;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _Segmented(
                labels: [
                  for (final device in OrdinaryDevice.values) device.label,
                ],
                selectedIndex: OrdinaryDevice.values.indexOf(devices.selected),
                onSelected: (index) =>
                    devices.select(OrdinaryDevice.values[index]),
              ),
            ),
            const SizedBox(width: Tokens.x3),
            _SyncButton(devices: devices),
          ],
        ),
        const SizedBox(height: Tokens.x3),
        Text(devices.syncLabel, style: Tokens.caption),
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
                    borderRadius:
                        BorderRadius.all(Radius.circular(Tokens.rPill)),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < count; i++)
                    Expanded(
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
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SyncButton extends StatelessWidget {
  const _SyncButton({required this.devices});

  final Devices devices;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: devices.syncing ? null : devices.sync,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration:
            const BoxDecoration(shape: BoxShape.circle, color: Tokens.paper2),
        child: devices.syncing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Tokens.text),
                ),
              )
            : const Icon(Icons.sync_rounded, color: Tokens.text, size: 20),
      ),
    );
  }
}

// ----------------------------------------------------------- speed dial row

/// Contacts the Band can call. Picking uses the system's own contact picker
/// (`CNContactPickerViewController` under the hood), which iOS treats as
/// permissionless — the user is choosing from a system UI, not handing the
/// app blanket read access to their address book.
class _SpeedDialRow extends StatelessWidget {
  const _SpeedDialRow({required this.speedDial});

  /// Null for the one frame before [didChangeDependencies] has resolved it out
  /// of the scope.
  final SpeedDial? speedDial;

  Future<void> _addContact() async {
    final store = speedDial;
    if (store == null) return;
    Contact? picked;
    try {
      picked = await FlutterContacts.native.showPicker(properties: {
        ContactProperty.phone,
      });
    } catch (_) {
      return;
    }
    if (picked == null || picked.phones.isEmpty) return;
    store.add(SpeedDialContact(
      name: picked.displayName ?? 'Unknown',
      phone: picked.phones.first.number,
    ));
  }

  Future<void> _call(SpeedDialContact contact) async {
    try {
      await launchUrl(Uri.parse('tel:${contact.dialNumber}'));
    } catch (_) {
      // Nothing sensible to show the user here — the dialer either opens or
      // it doesn't, and a failure means there's no dialer to fall back to.
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = speedDial?.contacts ?? const <SpeedDialContact>[];
    return Wrap(
      spacing: Tokens.x3,
      runSpacing: Tokens.x3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final contact in contacts)
          _Chip(
            label: contact.initial,
            onTap: () => _call(contact),
            onLongPress: () => speedDial?.removeAt(contacts.indexOf(contact)),
          ),
        _Chip(icon: Icons.add_rounded, filled: true, onTap: _addContact),
      ],
    );
  }
}

/// A 34px circle: a contact's initial, or the black "+".
class _Chip extends StatelessWidget {
  const _Chip({
    this.label,
    this.icon,
    this.filled = false,
    required this.onTap,
    this.onLongPress,
  });

  final String? label;
  final IconData? icon;
  final bool filled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
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
                style: Tokens.bodyStrong.copyWith(fontSize: 13, height: 1),
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
        Positioned(
          top: 14,
          right: 14,
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
          const Icon(Icons.chevron_right_rounded,
              color: Tokens.textFaint, size: 22),
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
                      ? 'Ordi is listening and staying quiet.'
                      : '$count captured. Ordi is staying quiet.',
                  style: Tokens.caption,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              store.stop();
              OrdiAudio.setRecording(false);
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: Tokens.x3, vertical: 7),
              decoration: BoxDecoration(
                color: Tokens.paper,
                borderRadius: BorderRadius.circular(Tokens.rPill),
              ),
              child: Text(
                'Stop',
                style: Tokens.bodyStrong
                    .copyWith(fontSize: 13, color: Tokens.danger, height: 1.2),
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
  const _TaskList({required this.tasks, required this.onToggle});

  final List<BriefTask> tasks;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return Text(
        "Nothing yet — Ordi will pull tasks out of your conversations "
        'as you go.',
        style: Tokens.body.copyWith(color: Tokens.textFaint),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < tasks.length; i++)
          Padding(
            padding: EdgeInsets.only(
                bottom: i == tasks.length - 1 ? 0 : Tokens.x4),
            child: GestureDetector(
              onTap: () => onToggle(i),
              behavior: HitTestBehavior.opaque,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            tasks[i].done ? Tokens.text : Colors.transparent,
                        border: Border.all(
                          color:
                              tasks[i].done ? Tokens.text : Tokens.textFaint,
                          width: 1.8,
                        ),
                      ),
                      child: tasks[i].done
                          ? const Icon(Icons.check_rounded,
                              size: 14, color: Tokens.accentInk)
                          : null,
                    ),
                  ),
                  const SizedBox(width: Tokens.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tasks[i].title,
                          style: Tokens.heading.copyWith(
                            fontSize: 17,
                            color:
                                tasks[i].done ? Tokens.textFaint : Tokens.text,
                            decoration: tasks[i].done
                                ? TextDecoration.lineThrough
                                : null,
                            decorationColor: Tokens.textFaint,
                          ),
                        ),
                        // Only reminders asked for out loud have a time;
                        // tasks scraped out of a finished conversation don't,
                        // and shouldn't pretend to.
                        if (tasks[i].dueAt != null && !tasks[i].done) ...[
                          const SizedBox(height: 2),
                          Text(
                            dueLabel(tasks[i].dueAt!),
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
    );
  }
}
