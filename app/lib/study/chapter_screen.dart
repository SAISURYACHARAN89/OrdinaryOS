import 'package:flutter/material.dart';

import '../models/study.dart';
import '../ui/glass.dart';
import '../ui/tokens.dart';
import 'note_wizard_screen.dart';
import 'study_player.dart';

/// Notes inside one chapter — add, play, edit, or swipe one away.
class ChapterScreen extends StatefulWidget {
  const ChapterScreen({
    super.key,
    required this.library,
    required this.chapterIndex,
  });

  final StudyLibrary library;
  final int chapterIndex;

  @override
  State<ChapterScreen> createState() => _ChapterScreenState();
}

class _ChapterScreenState extends State<ChapterScreen> {
  final StudyPlayer _player = StudyPlayer();

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  StudyChapter get _chapter => widget.library.chapters[widget.chapterIndex];

  /// The chapter name first, then each note's own name ahead of its content —
  /// so listening to a whole chapter tells you what you're hearing as it
  /// goes, rather than reading every note's raw text back to back with no
  /// sense of where one ends and the next begins.
  void _playChapter() {
    final chapter = _chapter;
    _player.playAll([
      chapter.name,
      for (final note in chapter.notes) ...[note.name, note.content],
    ]);
  }

  void _playNote(StudyNote note) {
    _player.playAll([note.name, note.content]);
  }

  Future<void> _addNote() async {
    final result = await Navigator.of(context).push<(String, String)>(
      MaterialPageRoute(builder: (_) => const NoteWizardScreen()),
    );
    if (result != null && mounted) {
      setState(() {
        widget.library.addNote(widget.chapterIndex, result.$1, result.$2);
      });
    }
  }

  Future<void> _editNote(int noteIndex) async {
    final note = _chapter.notes[noteIndex];
    final result = await Navigator.of(context).push<(String, String)>(
      MaterialPageRoute(
        builder: (_) => NoteWizardScreen(
          initialName: note.name,
          initialContent: note.content,
          startOnContent: true,
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        widget.library
            .updateNote(widget.chapterIndex, noteIndex, result.$1, result.$2);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final chapter = _chapter;
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.chevron_left_rounded,
                color: Tokens.text, size: 30),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text(chapter.name, style: Tokens.heading),
          centerTitle: true,
          actions: [
            ValueListenableBuilder<bool>(
              valueListenable: _player.speaking,
              builder: (context, speaking, _) => IconButton(
                icon: Icon(
                  speaking ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  color: Tokens.text,
                ),
                onPressed: chapter.notes.isEmpty
                    ? null
                    : () => speaking ? _player.stop() : _playChapter(),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: chapter.notes.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Tokens.x6),
                    child: Text(
                      "No notes yet. Add one and it'll sync to the Band.",
                      textAlign: TextAlign.center,
                      style: Tokens.body,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                      Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x10),
                  itemCount: chapter.notes.length,
                  itemBuilder: (context, index) {
                    final note = chapter.notes[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Tokens.x3),
                      child: Dismissible(
                        key: ValueKey(note),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) => setState(
                          () => widget.library
                              .removeNoteAt(widget.chapterIndex, index),
                        ),
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding:
                              const EdgeInsets.symmetric(horizontal: Tokens.x5),
                          decoration: BoxDecoration(
                            color: Tokens.danger.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(Tokens.rMedium),
                          ),
                          child: const Icon(Icons.delete_outline_rounded,
                              color: Tokens.danger),
                        ),
                        child: GlassSurface(
                          radius: Tokens.rMedium,
                          onTap: () => _editNote(index),
                          padding: const EdgeInsets.symmetric(
                              horizontal: Tokens.x4, vertical: Tokens.x1),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  note.name,
                                  style: Tokens.heading,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable: _player.speaking,
                                builder: (context, speaking, _) => IconButton(
                                  icon: Icon(
                                    speaking
                                        ? Icons.stop_circle_outlined
                                        : Icons.play_circle_outline_rounded,
                                    color: Tokens.textSoft,
                                  ),
                                  onPressed: () => speaking
                                      ? _player.stop()
                                      : _playNote(note),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _addNote,
          backgroundColor: Tokens.text,
          child: const Icon(Icons.add_rounded, color: Colors.white),
        ),
      ),
    );
  }
}
