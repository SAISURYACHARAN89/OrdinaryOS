import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One entry inside a chapter — a name plus free-text content the user typed
/// or pasted in. Canonically this belongs on the Band; the app is just where
/// it's authored and synced from until the Band exists to hold it itself.
class StudyNote {
  StudyNote({required this.name, required this.content});

  String name;
  String content;

  Map<String, dynamic> toJson() => {'name': name, 'content': content};

  factory StudyNote.fromJson(Map<String, dynamic> json) => StudyNote(
        name: json['name'] as String? ?? '',
        content: json['content'] as String? ?? '',
      );
}

class StudyChapter {
  StudyChapter({required this.name}) : notes = [];

  String name;
  final List<StudyNote> notes;

  Map<String, dynamic> toJson() => {
        'name': name,
        'notes': notes.map((n) => n.toJson()).toList(),
      };

  factory StudyChapter.fromJson(Map<String, dynamic> json) {
    final chapter = StudyChapter(name: json['name'] as String? ?? '');
    final rawNotes = json['notes'] as List<dynamic>? ?? const [];
    chapter.notes.addAll(
      rawNotes.map((n) => StudyNote.fromJson(n as Map<String, dynamic>)),
    );
    return chapter;
  }
}

/// Chapters and notes the user has authored, persisted locally so they
/// survive closing the app.
///
/// This content is written by hand — pasted in, dictated, named one note at
/// a time — so losing it on every relaunch would be a real loss, unlike the
/// device battery numbers elsewhere in this app, which are mock telemetry
/// that's *supposed* to look fresh each time. Storage is a single JSON blob
/// in `shared_preferences`: the whole library is small (chapters of short
/// notes, not a real database's worth of content), so one key holding one
/// encoded list is simpler than a real schema for what this is.
class StudyLibrary extends ChangeNotifier {
  static const _prefsKey = 'study_library_v1';

  final List<StudyChapter> _chapters = [];

  List<StudyChapter> get chapters => List.unmodifiable(_chapters);

  /// Reads whatever was saved last, if anything. Call once at startup; the
  /// UI listens for the change this fires rather than needing to be told
  /// when loading finishes.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    final decoded = jsonDecode(raw) as List<dynamic>;
    _chapters
      ..clear()
      ..addAll(
        decoded.map((e) => StudyChapter.fromJson(e as Map<String, dynamic>)),
      );
    notifyListeners();
  }

  void addChapter(String name) {
    _chapters.add(StudyChapter(name: name));
    notifyListeners();
    _persist();
  }

  void removeChapterAt(int index) {
    _chapters.removeAt(index);
    notifyListeners();
    _persist();
  }

  void addNote(int chapterIndex, String name, String content) {
    _chapters[chapterIndex].notes.add(StudyNote(name: name, content: content));
    notifyListeners();
    _persist();
  }

  void updateNote(int chapterIndex, int noteIndex, String name, String content) {
    final note = _chapters[chapterIndex].notes[noteIndex];
    note.name = name;
    note.content = content;
    notifyListeners();
    _persist();
  }

  void removeNoteAt(int chapterIndex, int noteIndex) {
    _chapters[chapterIndex].notes.removeAt(noteIndex);
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_chapters.map((c) => c.toJson()).toList()),
    );
  }
}
