import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BriefTask {
  BriefTask({required this.title, this.done = false});

  final String title;
  bool done;

  Map<String, dynamic> toJson() => {'title': title, 'done': done};

  factory BriefTask.fromJson(Map<String, dynamic> json) => BriefTask(
        title: json['title'] as String? ?? '',
        done: json['done'] as bool? ?? false,
      );
}

/// Tasks and reminders Ordi has actually pulled out of finished
/// conversations — see `ConversationLog._finalize`, which is what calls the
/// backend and hands the extracted titles here.
///
/// Deliberately not fed by anything else: there is no keyword scanning of
/// live speech, no per-exchange extraction. One finished conversation
/// produces at most one small batch of tasks, once, which is both cheaper and
/// far less prone to inventing a task from an offhand remark than extracting
/// continuously would be.
class AiBrief extends ChangeNotifier {
  static const _prefsKey = 'ai_brief_tasks_v1';

  final List<BriefTask> _tasks = [];

  List<BriefTask> get tasks => List.unmodifiable(_tasks);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    final decoded = jsonDecode(raw) as List<dynamic>;
    _tasks
      ..clear()
      ..addAll(decoded.map((e) => BriefTask.fromJson(e as Map<String, dynamic>)));
    notifyListeners();
  }

  /// Adds whatever of [titles] isn't already present, case-insensitively —
  /// a session that gets finalised twice (it shouldn't, but nothing enforces
  /// that at this layer) must not duplicate its tasks.
  void addExtracted(List<String> titles) {
    final existing = _tasks.map((t) => t.title.toLowerCase()).toSet();
    var added = false;
    for (final title in titles) {
      final trimmed = title.trim();
      if (trimmed.isEmpty || existing.contains(trimmed.toLowerCase())) {
        continue;
      }
      _tasks.add(BriefTask(title: trimmed));
      existing.add(trimmed.toLowerCase());
      added = true;
    }
    if (added) {
      notifyListeners();
      _persist();
    }
  }

  void toggle(int index) {
    _tasks[index].done = !_tasks[index].done;
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_tasks.map((t) => t.toJson()).toList()),
    );
  }
}
