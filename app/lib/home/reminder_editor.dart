import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/ai_brief.dart';
import '../ui/surface.dart';
import '../ui/time_format.dart';
import '../ui/tokens.dart';

/// Opens the editor for one task as a sheet from the bottom of the screen:
/// rename it, set or change or clear its time, or delete it.
Future<void> showReminderEditor(
  BuildContext context, {
  required AiBrief brief,
  required BriefTask task,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Tokens.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Tokens.rLarge)),
    ),
    builder: (_) => _ReminderEditor(brief: brief, task: task),
  );
}

class _ReminderEditor extends StatefulWidget {
  const _ReminderEditor({required this.brief, required this.task});

  final AiBrief brief;
  final BriefTask task;

  @override
  State<_ReminderEditor> createState() => _ReminderEditorState();
}

class _ReminderEditorState extends State<_ReminderEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.task.title);
  late DateTime? _when = widget.task.dueAt;

  /// The wheel stays folded away until the time is tapped.
  bool _picking = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  DateTime _startForWheel() {
    final now = DateTime.now();
    final due = _when;
    if (due != null && due.isAfter(now)) return due;
    return DateTime(now.year, now.month, now.day, now.hour + 1);
  }

  void _save() {
    if (_title.text.trim().isEmpty) return;
    widget.brief.edit(
      widget.task,
      title: _title.text,
      dueAt: _when,
      clearDue: _when == null,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final when = _when;
    final past = when != null && !when.isAfter(DateTime.now());
    return Padding(
      padding: EdgeInsets.fromLTRB(Tokens.gutter, Tokens.x3, Tokens.gutter,
          Tokens.x5 + MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Tokens.rule,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: Tokens.x4),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              style: Tokens.title,
              decoration: InputDecoration(
                hintText: 'Reminder',
                hintStyle: Tokens.title.copyWith(color: Tokens.textFaint),
                border: InputBorder.none,
                isDense: true,
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: Tokens.x3),
            // One row for the time: tap to change it, ✕ to drop it.
            GestureDetector(
              onTap: () => setState(() {
                _when ??= _startForWheel();
                _picking = !_picking;
              }),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: Tokens.x4, vertical: Tokens.x3),
                decoration: BoxDecoration(
                  color: Tokens.paper2,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(Icons.schedule_rounded,
                        size: 18,
                        color: past ? Tokens.danger : Tokens.textSoft),
                    const SizedBox(width: Tokens.x3),
                    Expanded(
                      child: Text(
                        when == null
                            ? 'Add a time'
                            : past
                                ? '${dueLabel(when)} — already passed'
                                : dueLabel(when),
                        style: Tokens.bodyStrong.copyWith(
                          color: when == null
                              ? Tokens.textSoft
                              : past
                                  ? Tokens.danger
                                  : Tokens.text,
                        ),
                      ),
                    ),
                    if (when != null)
                      GestureDetector(
                        onTap: () => setState(() {
                          _when = null;
                          _picking = false;
                        }),
                        child: const Icon(Icons.close_rounded,
                            size: 18, color: Tokens.textFaint),
                      ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: _picking && when != null
                  ? SizedBox(
                      height: 170,
                      child: CupertinoDatePicker(
                        mode: CupertinoDatePickerMode.dateAndTime,
                        initialDateTime: when,
                        minimumDate: when.isBefore(DateTime.now())
                            ? when
                            : DateTime.now(),
                        use24hFormat: false,
                        onDateTimeChanged: (value) =>
                            setState(() => _when = value),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            const SizedBox(height: Tokens.x4),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _title,
              builder: (context, value, _) => InkButton(
                label: 'Save',
                onPressed: value.text.trim().isEmpty || past ? null : _save,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
