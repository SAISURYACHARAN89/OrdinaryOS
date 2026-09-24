import 'package:flutter/material.dart';

import '../models/study.dart';
import '../ui/surface.dart';
import '../ui/tokens.dart';
import 'chapter_screen.dart';

/// Chapters, as sketched: name a chapter, fill it with notes, and the whole
/// thing syncs to the Band from the dashboard's sync button.
class StudyScreen extends StatefulWidget {
  const StudyScreen({super.key, required this.library});

  final StudyLibrary library;

  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  Future<void> _addChapter() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('New chapter', style: Tokens.heading),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: Tokens.bodyStrong.copyWith(fontSize: 16),
          decoration: InputDecoration(
            hintText: 'Chapter name',
            hintStyle: Tokens.body.copyWith(color: Tokens.textFaint),
            enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Tokens.rule, width: 2)),
            focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Tokens.text, width: 2)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      widget.library.addChapter(name);
    }
  }

  /// The trash icon deletes on a single tap, so it asks first — swiping a row
  /// away is a deliberate gesture and does not.
  Future<void> _confirmDelete(StudyChapter chapter) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${chapter.name}"?', style: Tokens.heading),
        content: Text(
          chapter.notes.isEmpty
              ? 'This chapter is empty.'
              : 'Its ${chapter.notes.length == 1 ? 'note' : '${chapter.notes.length} notes'} will be deleted with it.',
          style: Tokens.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Delete',
                style: Tokens.bodyStrong.copyWith(color: Tokens.danger)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      final index = widget.library.chapters.indexOf(chapter);
      if (index >= 0) widget.library.removeChapterAt(index);
    }
  }

  void _openChapter(int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChapterScreen(library: widget.library, chapterIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: screenBar(context, text: 'Study Mode'),
        // Listens directly to the library rather than relying only on the
        // setState calls below — loading persisted chapters finishes
        // asynchronously, and this is what makes them appear if that
        // happens while this screen is already open.
        body: AnimatedBuilder(
          animation: widget.library,
          builder: (context, _) {
            final chapters = widget.library.chapters;
            return SafeArea(
              top: false,
              child: chapters.isEmpty
              ? const EmptyNote(
                  'No chapters yet. Add one to start building notes for '
                  'the Band to read back.',
                )
              : ListView.builder(
                  // Bottom padding clears the floating "+" so it never sits on
                  // top of the last row.
                  padding: const EdgeInsets.fromLTRB(
                      Tokens.gutter, Tokens.x2, Tokens.gutter, 96),
                  itemCount: chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = chapters[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Tokens.x3 - 2),
                      child: Dismissible(
                        key: ValueKey(chapter),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) =>
                            widget.library.removeChapterAt(index),
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
                          onTap: () => _openChapter(index),
                          padding: const EdgeInsets.fromLTRB(
                              Tokens.x4, Tokens.x3 + 3, Tokens.x2, Tokens.x3 + 3),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  chapter.name,
                                  style: Tokens.heading.copyWith(fontSize: 16.5),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: Tokens.x2),
                              Text(
                                chapter.notes.length == 1
                                    ? '1 note'
                                    : '${chapter.notes.length} notes',
                                style: Tokens.caption,
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: 'Delete chapter',
                                icon: const Icon(Icons.delete_outline_rounded,
                                    color: Tokens.textFaint, size: 20),
                                onPressed: () => _confirmDelete(chapter),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
            );
          },
        ),
        floatingActionButton: InkFab(onPressed: _addChapter),
      ),
    );
  }
}
