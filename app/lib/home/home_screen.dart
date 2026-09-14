import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../history/history_screen.dart';
import '../main.dart';
import '../models/ai_brief.dart';
import '../models/device.dart';
import '../models/speed_dial.dart';
import '../models/study.dart';
import '../ordi/ordi_screen.dart';
import '../study/study_screen.dart';
import '../ui/device_icons.dart';
import '../ui/glass.dart';
import '../ui/tokens.dart';

/// The dashboard.
///
/// Follows the hand sketch: identity and balance at the top, the two products
/// side by side, then the controls that act on them, then the things you
/// actually do — study, talk, review. Tasks Ordi extracted sit at the bottom,
/// where a glance finds them without any navigation.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Devices _devices = Devices();
  final SpeedDial _speedDial = SpeedDial();

  /// Owned here rather than by StudyScreen so notes survive leaving and
  /// returning to Study Mode within the same app run.
  final StudyLibrary _study = StudyLibrary();

  /// Owned at the app root (`main.dart`), not here — it needs to keep
  /// receiving tasks from finished conversations whether or not the
  /// dashboard is the screen currently showing. Picked up in
  /// [didChangeDependencies] since reaching it needs a `BuildContext`.
  AiBrief? _brief;

  @override
  void initState() {
    super.initState();
    _devices.addListener(_onDevices);
    _speedDial.addListener(_onDevices);
    _devices.load();
    _speedDial.load();
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
  }

  @override
  void dispose() {
    _devices.removeListener(_onDevices);
    _devices.dispose();
    _speedDial.removeListener(_onDevices);
    _speedDial.dispose();
    _brief?.removeListener(_onDevices);
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
    // Scaffold matters here beyond providing a screen frame: it wraps its
    // content in a Material widget, which is what supplies a real
    // DefaultTextStyle. Without one, every Text on this screen was falling
    // back to Flutter's DefaultTextStyle.fallback() — a loud double yellow
    // underline that exists specifically to flag missing style context, and
    // it renders in release builds too. OrdiScreen already had a Scaffold,
    // which is why only the dashboard showed this.
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
              const _TopBar(balance: 1350),
              const SizedBox(height: Tokens.x5),

              // The two products, given equal weight — neither is the accessory.
              Row(
                children: [
                  Expanded(child: _DeviceCard(state: _devices.audio)),
                  const SizedBox(width: Tokens.x3),
                  Expanded(child: _DeviceCard(state: _devices.band)),
                ],
              ),
              const SizedBox(height: Tokens.x3),

              _ControlRow(devices: _devices),
              const SizedBox(height: Tokens.x3),

              _SpeedDialRow(speedDial: _speedDial),
              const SizedBox(height: Tokens.x3),

              // IntrinsicHeight so the shorter card ("Conversate", one line)
              // matches the taller one ("Study Mode", two lines) rather than
              // both being forced to a fixed height that clips whichever title
              // wraps.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _ActionCard(
                        title: 'Study Mode',
                        icon: Icons.menu_book_rounded,
                        onTap: () => _openStudyMode(context),
                      ),
                    ),
                    const SizedBox(width: Tokens.x3),
                    Expanded(
                      child: _ActionCard(
                        title: 'Conversate',
                        icon: Icons.graphic_eq_rounded,
                        onTap: () => _openOrdi(context),
                        // History used to be its own row on the dashboard;
                        // it lives here now, a tap away from the thing it's
                        // a record of, rather than competing for space above
                        // the tasks.
                        trailingIcon: Icons.history_rounded,
                        onTrailingTap: () => _openHistory(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Tokens.x6),

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

// ------------------------------------------------------------------ top bar

class _TopBar extends StatelessWidget {
  const _TopBar({required this.balance});

  final int balance;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('Ordinary OS', style: Tokens.title),
        const Spacer(),
        _CreditsPill(balance: balance),
        const SizedBox(width: Tokens.x3),
        // Profile. A ring rather than a filled avatar until there are
        // accounts — nothing here is signed in yet.
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Tokens.inkRaised,
            border: Border.all(color: Tokens.edgeLit, width: 1),
          ),
          alignment: Alignment.center,
          child: Text(
            'O',
            style: Tokens.label.copyWith(
              color: Tokens.text,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// The credits balance, as a quiet pill rather than raw text next to the
/// title — it reads as a small piece of chrome rather than competing with
/// "Ordinary OS" for attention.
class _CreditsPill extends StatelessWidget {
  const _CreditsPill({required this.balance});

  final int balance;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Tokens.x3, vertical: 7),
      decoration: BoxDecoration(
        color: Tokens.inkRaised,
        borderRadius: BorderRadius.circular(Tokens.rPill),
        border: Border.all(color: Tokens.edgeLit, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt_rounded, size: 15, color: Tokens.textSoft),
          const SizedBox(width: 4),
          Text(
            '$balance',
            style: Tokens.label.copyWith(
              color: Tokens.text,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- device card

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.state});

  final DeviceState state;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      radius: Tokens.rLarge,
      padding: const EdgeInsets.fromLTRB(
        Tokens.x4,
        Tokens.x4,
        Tokens.x4,
        Tokens.x3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The connection dot only — the device already names itself with
          // its shape, and a text label underneath was redundant with the
          // glyph sitting right there.
          Align(
            alignment: Alignment.centerLeft,
            child: _StatusDot(connected: state.connected),
          ),
          const SizedBox(height: Tokens.x4),
          Center(
            child: DeviceGlyph(
              device: state.device,
              size: 78,
              color: Tokens.text,
            ),
          ),
          const SizedBox(height: Tokens.x4),
          // Battery is plain black — colour-coding it drew the eye to the
          // number for the wrong reason. If a low-battery signal is wanted
          // later, it belongs on the status dot, not the numeral.
          Text(state.batteryLabel, style: Tokens.numeral),
        ],
      ),
    );
  }
}

/// The connected indicator, matching iOS: a small filled dot with a soft halo,
/// not a badge or a word.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final colour = connected ? Tokens.connected : Tokens.textFaint;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colour,
        boxShadow: connected
            ? [BoxShadow(color: colour.withValues(alpha: 0.45), blurRadius: 6)]
            : null,
      ),
    );
  }
}

// ------------------------------------------------------------- control row

/// Device selector plus sync, as drawn: a segmented track where the active
/// device is filled, and a separate square sync button beside it.
///
/// The selector is `liquid_glass_widgets`' own [GlassSegmentedControl] rather
/// than a hand-built sliding thumb — `dragBehavior: selectIndicator` is what
/// makes the pill genuinely draggable between segments (not just tappable),
/// with the jelly squash-and-stretch physics real iOS 26 controls have. Per
/// the package's own guidance this must NOT be nested inside a [GlassSurface]
/// — doing so would both flatten its refraction and clip its drag overshoot —
/// so it renders standalone, on its own layer, with its own light background
/// standing in for the track.
class _ControlRow extends StatelessWidget {
  const _ControlRow({required this.devices});

  final Devices devices;

  @override
  Widget build(BuildContext context) {
    final devicesList = OrdinaryDevice.values;
    final selectedIndex = devicesList.indexOf(devices.selected);

    return Row(
      children: [
        Expanded(
          child: GlassSegmentedControl(
            segments: [
              for (final device in devicesList)
                GlassSegment(
                  icon: DeviceGlyph(device: device, size: 36),
                  id: device,
                ),
            ],
            selectedIndex: selectedIndex,
            onSegmentSelected: (index) => devices.select(devicesList[index]),
            dragBehavior: SegmentDragBehavior.selectIndicator,
            height: 54,
            borderRadius: Tokens.rMedium,
            useOwnLayer: true,
            backgroundColor: Colors.white.withValues(alpha: 0.34),
            indicatorColor: Tokens.inkRaised,
            selectedIconColor: Tokens.text,
            unselectedIconColor: Tokens.textFaint,
          ),
        ),
        const SizedBox(width: Tokens.x3),
        _SyncButton(devices: devices),
      ],
    );
  }
}

class _SyncButton extends StatelessWidget {
  const _SyncButton({required this.devices});

  final Devices devices;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      radius: Tokens.rMedium,
      padding: EdgeInsets.zero,
      onTap: devices.syncing ? null : devices.sync,
      child: SizedBox(
        width: 62,
        height: 54,
        child: Center(
          child: devices.syncing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Tokens.text),
                  ),
                )
              : const Icon(Icons.sync_rounded, color: Tokens.text, size: 24),
        ),
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

  final SpeedDial speedDial;

  Future<void> _addContact() async {
    Contact? picked;
    try {
      picked =
          await FlutterContacts.native.showPicker(properties: {
        ContactProperty.phone,
      });
    } catch (_) {
      return;
    }
    if (picked == null || picked.phones.isEmpty) return;
    speedDial.add(SpeedDialContact(
      name: picked.displayName ?? 'Unknown',
      phone: picked.phones.first.number,
    ));
  }

  Future<void> _call(SpeedDialContact contact) async {
    try {
      await launchUrl(Uri(scheme: 'tel', path: contact.phone));
    } catch (_) {
      // Nothing sensible to show the user here — the dialer either opens or
      // it doesn't, and a failure means there's no dialer to fall back to.
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = speedDial.contacts;
    return GlassSurface(
      radius: Tokens.rMedium,
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.x4,
        vertical: Tokens.x4,
      ),
      child: Row(
        children: [
          Text('Speed dial', style: Tokens.heading),
          const Spacer(),
          for (final contact in contacts) ...[
            _ContactAvatar(
              contact: contact,
              onTap: () => _call(contact),
              onLongPress: () =>
                  speedDial.removeAt(contacts.indexOf(contact)),
            ),
            const SizedBox(width: Tokens.x2),
          ],
          _AddContactButton(onTap: _addContact),
        ],
      ),
    );
  }
}

class _ContactAvatar extends StatelessWidget {
  const _ContactAvatar({
    required this.contact,
    required this.onTap,
    required this.onLongPress,
  });

  final SpeedDialContact contact;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Tokens.inkRaised,
          border: Border.all(color: Tokens.edgeLit, width: 1),
        ),
        alignment: Alignment.center,
        child: Text(
          contact.initial,
          style:
              Tokens.label.copyWith(color: Tokens.text, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _AddContactButton extends StatelessWidget {
  const _AddContactButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: const CircleAvatar(
        radius: 16,
        backgroundColor: Tokens.text,
        child: Icon(Icons.add_rounded, color: Colors.white, size: 18),
      ),
    );
  }
}

// ------------------------------------------------------------- action cards

class _ActionCard extends StatelessWidget {
  const _ActionCard({
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
  /// History, since a whole extra row on the dashboard was more than a
  /// record of past sessions needed.
  final IconData? trailingIcon;
  final VoidCallback? onTrailingTap;

  @override
  Widget build(BuildContext context) {
    final card = GlassSurface(
      radius: Tokens.rLarge,
      onTap: onTap,
      padding: const EdgeInsets.all(Tokens.x5),
      // No fixed height: the card sizes to its content, and IntrinsicHeight
      // on the parent Row makes both cards match the taller one. A fixed
      // height here is what clipped "Study Mode" before.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Tokens.textSoft, size: 22),
          const SizedBox(height: Tokens.x8),
          Text(title, style: Tokens.title),
        ],
      ),
    );

    if (trailingIcon == null) return card;

    // The trailing icon sits *outside* GlassSurface's own child tree, not
    // nested inside it — GlassSurface's own full-card InkWell paints on top
    // of whatever is passed as its child, so a button nested in there is
    // visually present but never actually reachable by touch: taps land on
    // the card's own InkWell first. As a sibling layered above the whole
    // card instead, this button gets first claim on taps in its own small
    // area, and everywhere else still falls through to the card underneath.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        Positioned(
          top: -8,
          right: -8,
          child: IconButton(
            icon: Icon(trailingIcon, color: Tokens.textFaint, size: 20),
            onPressed: onTrailingTap,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- task list

/// What Ordi pulled out of your conversations.
///
/// Sits bare on the backdrop rather than in a card: these are the one thing on
/// the screen you act on rather than navigate into, and boxing them would make
/// them read as another destination.
///
/// Real now, not placeholder content — each of these came from
/// `AiBrief.addExtracted`, called once a finished conversation has actually
/// been analysed. An empty list means no conversation has surfaced a task
/// yet, not that the feature is unbuilt.
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
        style: Tokens.body,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < tasks.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: Tokens.x4),
            child: GestureDetector(
              onTap: () => onToggle(i),
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: tasks[i].done ? Tokens.text : Colors.transparent,
                      border: Border.all(
                        color: tasks[i].done ? Tokens.text : Tokens.edgeLit,
                        width: 1.6,
                      ),
                    ),
                    child: tasks[i].done
                        ? const Icon(
                            Icons.check_rounded,
                            size: 15,
                            color: Colors.white,
                          )
                        : null,
                  ),
                  const SizedBox(width: Tokens.x4),
                  Expanded(
                    child: Text(
                      tasks[i].title,
                      style: Tokens.title.copyWith(
                        color: tasks[i].done ? Tokens.textFaint : Tokens.text,
                        decoration:
                            tasks[i].done ? TextDecoration.lineThrough : null,
                        decorationColor: Tokens.textFaint,
                      ),
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
