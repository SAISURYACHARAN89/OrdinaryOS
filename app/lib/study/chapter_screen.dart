import 'package:flutter/material.dart';

import '../models/study.dart';
import '../ui/surface.dart';
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
        appBar: screenBar(
          context,
          text: chapter.name,
          actions: [
            ValueListenableBuilder<bool>(
              valueListenable: _player.speaking,
              builder: (context, speaking, _) => Padding(
                padding: const EdgeInsets.only(right: Tokens.x4),
                child: RoundIconButton(
                  icon: speaking ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  iconSize: 20,
                  filled: speaking,
                  tooltip: speaking ? 'Stop' : 'Play chapter',
                  onTap: chapter.notes.isEmpty
                      ? null
                      : () => speaking ? _player.stop() : _playChapter(),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: chapter.notes.isEmpty
              ? const EmptyNote("No notes yet. Add one and it'll sync to the Band.")
              : ListView.builder(
                  // Bottom padding clears the floating "+" so it never sits on
                  // top of the last row.
                  padding: const EdgeInsets.fromLTRB(
                      Tokens.gutter, Tokens.x2, Tokens.gutter, 96),
                  itemCount: chapter.notes.length,
                  itemBuilder: (context, index) {
                    final note = chapter.notes[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Tokens.x3 - 2),
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
                            color: Tokens.danger.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(Icons.delete_outline_rounded,
                              color: Tokens.danger),
                        ),
                        child: Surface(
                          radius: 20,
                          onTap: () => _editNote(index),
                          padding: const EdgeInsets.fromLTRB(
                              Tokens.x4, Tokens.x3 - 1, Tokens.x3 - 1, Tokens.x3 - 1),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  note.name,
                                  style: Tokens.heading.copyWith(fontSize: 16),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: Tokens.x3),
                              ValueListenableBuilder<bool>(
                                valueListenable: _player.speaking,
                                builder: (context, speaking, _) =>
                                    RoundIconButton(
                                  icon: speaking
                                      ? Icons.stop_rounded
                                      : Icons.play_arrow_rounded,
                                  iconSize: 20,
                                  filled: speaking,
                                  onPaper2: !speaking,
                                  onTap: () => speaking
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
        floatingActionButton: InkFab(onPressed: _addNote),
      ),
    );
  }
}
