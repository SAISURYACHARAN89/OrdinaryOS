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
  late bool _timed = widget.task.dueAt != null;
  late DateTime _when = _initialTime();

  /// The task's own time if it has one in the future, otherwise the next
  /// whole hour — a sensible place for the wheel to start.
  DateTime _initialTime() {
    final due = widget.task.dueAt;
    final now = DateTime.now();
    if (due != null && due.isAfter(now)) return due;
    return DateTime(now.year, now.month, now.day, now.hour + 1);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) return;
    widget.brief.edit(
      widget.task,
      title: _title.text,
      dueAt: _timed ? _when : null,
      clearDue: !_timed,
    );
    Navigator.of(context).pop();
  }

  void _delete() {
    widget.brief.remove(widget.task);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final past = _timed && !_when.isAfter(now);
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
            Text('Edit reminder', style: Tokens.title),
            const SizedBox(height: Tokens.x4),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              style: Tokens.bodyStrong.copyWith(fontSize: 17),
              decoration: InputDecoration(
                hintText: 'What to do',
                hintStyle: Tokens.body.copyWith(color: Tokens.textFaint),
                filled: true,
                fillColor: Tokens.paper2,
                contentPadding: const EdgeInsets.all(Tokens.x4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: Tokens.x3),
            Surface(
              radius: 16,
              padding: const EdgeInsets.symmetric(
                  horizontal: Tokens.x4, vertical: Tokens.x2),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Remind me at a time', style: Tokens.bodyStrong),
                        if (_timed)
                          Text(
                            past ? 'That time has passed' : dueLabel(_when),
                            style: Tokens.caption.copyWith(
                                color: past ? Tokens.danger : Tokens.textFaint),
                          ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: _timed,
                    activeTrackColor: Tokens.text,
                    onChanged: (on) => setState(() => _timed = on),
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: _timed
                  ? SizedBox(
                      height: 180,
                      child: CupertinoDatePicker(
                        mode: CupertinoDatePickerMode.dateAndTime,
                        initialDateTime: _when,
                        minimumDate: _when.isBefore(now) ? _when : now,
                        minuteInterval: 1,
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
            const SizedBox(height: Tokens.x2),
            TextButton(
              onPressed: _delete,
              child: Text('Delete',
                  style: Tokens.bodyStrong.copyWith(color: Tokens.danger)),
            ),
          ],
        ),
      ),
    );
  }
}
