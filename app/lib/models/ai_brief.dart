import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BriefTask {
  BriefTask({
    required this.title,
    required this.id,
    this.done = false,
    this.dueAt,
  });

  /// Editable from the dashboard.
  String title;

  /// Stable across restarts, and small enough to double as the iOS
  /// notification id — which is what it is actually for, since cancelling a
  /// scheduled reminder needs a handle that survives the app being killed.
  final int id;

  /// When this should fire, or null for an undated task. Tasks extracted from
  /// a finished conversation have no time; ones Ordi was asked for out loud
  /// usually do.
  ///
  /// Mutable because a reminder can be moved ("make it three instead") —
  /// the id stays the same so the OS notification is replaced, not duplicated.
  DateTime? dueAt;

  bool done;

  Map<String, dynamic> toJson() => {
        'title': title,
        'id': id,
        'done': done,
        if (dueAt != null) 'dueAt': dueAt!.toIso8601String(),
      };

  /// Tolerant of records written before tasks had times or ids — those decode
  /// as undated, with an id derived from the title so it stays stable.
  factory BriefTask.fromJson(Map<String, dynamic> json) {
    final title = json['title'] as String? ?? '';
    final rawDue = json['dueAt'] as String?;
    return BriefTask(
      title: title,
      id: json['id'] as int? ?? title.hashCode & 0x7fffffff,
      done: json['done'] as bool? ?? false,
      dueAt: rawDue == null ? null : DateTime.tryParse(rawDue),
    );
  }
}

/// Tasks and reminders, from two sources.
///
/// Most arrive after the fact: `ConversationLog._finalize` summarises a
/// finished conversation and hands the extracted titles to [addExtracted].
/// That path stays deliberately narrow — no keyword scanning of live speech,
/// no per-exchange extraction — because guessing tasks continuously invents
/// them from offhand remarks.
///
/// The rest arrive the moment they are asked for, through [add], when Ordi
/// calls its `create_reminder` tool mid-conversation. Those carry a time and
/// are the ones that actually fire.
class AiBrief extends ChangeNotifier {
  static const _prefsKey = 'ai_brief_tasks_v1';

  final List<BriefTask> _tasks = [];

  List<BriefTask> get tasks => List.unmodifiable(_tasks);

  /// Called with a task that has just been scheduled, so a listener can put it
  /// in front of the user at the right moment. Set by whoever owns firing;
  /// this store itself knows nothing about notifications.
  void Function(BriefTask task)? onScheduled;

  /// Called when a task's pending alert should be withdrawn — it was ticked
  /// off, deleted, or had its time cleared. Wired to the notification side.
  void Function(BriefTask task)? onCancelled;

  /// How long a finished task stays on the list before it goes: long enough
  /// to see it land, and to untick it if the tap was a mistake.
  static const lingerAfterDone = Duration(seconds: 10);

  /// One pending removal per task id: [lingerAfterDone] after it is ticked
  /// off, or after its reminder has gone off.
  final Map<int, Timer> _removals = {};

  /// Arms (or disarms) the automatic removal for one task.
  void _arm(BriefTask task) {
    _removals.remove(task.id)?.cancel();
    Duration? wait;
    if (task.done) {
      wait = lingerAfterDone;
    } else if (task.dueAt != null) {
      // Only a reminder that is still going to go off. One given a time
      // already in the past never alerts, so it stays until dealt with.
      final left = task.dueAt!.add(lingerAfterDone).difference(DateTime.now());
      if (!left.isNegative) wait = left;
    }
    if (wait == null) return;
    _removals[task.id] = Timer(wait, () {
      _removals.remove(task.id);
      remove(task);
    });
  }

  @override
  void dispose() {
    for (final timer in _removals.values) {
      timer.cancel();
    }
    _removals.clear();
    super.dispose();
  }

  /// Changes a task by hand. [dueAt] null with [clearDue] removes its time.
  void edit(BriefTask task, {String? title, DateTime? dueAt, bool clearDue = false}) {
    if (!_tasks.contains(task)) return;
    final trimmed = title?.trim();
    if (trimmed != null && trimmed.isNotEmpty) task.title = trimmed;
    final hadDue = task.dueAt != null;
    if (clearDue) {
      task.dueAt = null;
    } else if (dueAt != null) {
      task.dueAt = dueAt;
    }
    _lastTouched = task.id;
    _arm(task);
    notifyListeners();
    _persist();
    if (task.dueAt != null) {
      onScheduled?.call(task);
    } else if (hadDue) {
      onCancelled?.call(task);
    }
  }

  /// Every dated task that hasn't fired yet, soonest first.
  List<BriefTask> get upcoming {
    final now = DateTime.now();
    final pending = _tasks
        .where((t) => !t.done && t.dueAt != null && t.dueAt!.isAfter(now))
        .toList()
      ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
    return pending;
  }

  /// Adds one task immediately and returns it, or returns the existing task if
  /// the same thing is already on the list. Used by the `create_reminder`
  /// tool, which has to answer the model inside a second.
  BriefTask add(String title, {DateTime? at}) {
    final trimmed = title.trim();
    for (final task in _tasks) {
      if (task.title.toLowerCase() == trimmed.toLowerCase()) {
        // The same thing asked for again with a different time is a move, not
        // a duplicate. Returning the old task untouched is what made a
        // spoken "make it three instead" report success while the list still
        // said ten.
        if (at != null && task.dueAt != at) {
          task.done = false;
          reschedule(task, at);
        }
        return task;
      }
    }

    final task = BriefTask(
      title: trimmed,
      id: _nextId(),
      dueAt: at,
    );
    _tasks.add(task);
    _lastTouched = task.id;
    _arm(task);
    notifyListeners();
    _persist();
    if (task.dueAt != null) onScheduled?.call(task);
    return task;
  }

  /// The task most recently created or changed this run, so "move *that* to
  /// three" has something to point at without the model naming it exactly.
  int? _lastTouched;

  /// Finds a task from how a person (via the model) described it.
  ///
  /// "last" means the one just touched. Otherwise the best match by words:
  /// an exact title first, then one containing the other, then the most words
  /// in common — the model rarely repeats a title verbatim, and "call mom"
  /// has to find "Call mom tomorrow". Finished tasks are ignored, and null
  /// means nothing matched well enough, which callers must report honestly.
  BriefTask? find(String query) {
    final live = _tasks.where((t) => !t.done).toList();
    if (live.isEmpty) return null;

    final q = _norm(query);
    if (q.isEmpty || q == 'last' || q == 'that' || q == 'it') {
      final id = _lastTouched;
      if (id != null) {
        for (final t in live) {
          if (t.id == id) return t;
        }
      }
      final dated = live.where((t) => t.dueAt != null).toList();
      return dated.isEmpty ? live.last : dated.last;
    }

    for (final t in live) {
      if (_norm(t.title) == q) return t;
    }
    for (final t in live) {
      final title = _norm(t.title);
      if (title.contains(q) || q.contains(title)) return t;
    }

    final words = q.split(' ').where((w) => w.length > 2).toSet();
    if (words.isEmpty) return null;
    BriefTask? best;
    var bestScore = 0;
    for (final t in live) {
      final score = _norm(t.title).split(' ').where(words.contains).length;
      if (score > bestScore) {
        best = t;
        bestScore = score;
      }
    }
    return best;
  }

  static String _norm(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Moves an existing task to a new time. The id is kept, so the notification
  /// the OS already holds for it is replaced rather than joined by a second.
  void reschedule(BriefTask task, DateTime at) {
    task.dueAt = at;
    _lastTouched = task.id;
    _arm(task);
    notifyListeners();
    _persist();
    onScheduled?.call(task);
  }

  /// Removes a task outright. Returns whether it was there.
  bool remove(BriefTask task) {
    _removals.remove(task.id)?.cancel();
    final removed = _tasks.remove(task);
    if (removed) {
      notifyListeners();
      _persist();
      onCancelled?.call(task);
    }
    return removed;
  }

  /// Ids only have to be unique among live tasks and small enough for iOS to
  /// take as a notification id, so a rolling counter off the clock is plenty.
  int _nextId() {
    final used = _tasks.map((t) => t.id).toSet();
    var candidate = DateTime.now().millisecondsSinceEpoch % 0x7ffffff;
    while (used.contains(candidate)) {
      candidate = (candidate + 1) % 0x7ffffff;
    }
    return candidate;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    final decoded = jsonDecode(raw) as List<dynamic>;
    final loaded =
        decoded.map((e) => BriefTask.fromJson(e as Map<String, dynamic>));
    // Anything finished, or whose reminder already went off while the app
    // was closed, was due to be removed already.
    final cutoff = DateTime.now().subtract(lingerAfterDone);
    final keep = loaded.where((t) =>
        !t.done && (t.dueAt == null || t.dueAt!.isAfter(cutoff)));
    final dropped = loaded.length != keep.length;
    _tasks
      ..clear()
      ..addAll(keep);
    for (final task in _tasks) {
      _arm(task);
    }
    notifyListeners();
    if (dropped) _persist();
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
      _tasks.add(BriefTask(title: trimmed, id: _nextId()));
      existing.add(trimmed.toLowerCase());
      added = true;
    }
    if (added) {
      notifyListeners();
      _persist();
    }
  }

  /// Ticks a task off, or back on. A ticked-off task goes from the list
  /// [lingerAfterDone] later unless it is unticked first, and its reminder is
  /// withdrawn straight away; unticking a future reminder puts it back.
  void toggle(int index) {
    final task = _tasks[index];
    task.done = !task.done;
    _arm(task);
    notifyListeners();
    _persist();
    if (task.done) {
      onCancelled?.call(task);
    } else if (task.dueAt != null && task.dueAt!.isAfter(DateTime.now())) {
      onScheduled?.call(task);
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_tasks.map((t) => t.toJson()).toList()),
    );
  }
}
