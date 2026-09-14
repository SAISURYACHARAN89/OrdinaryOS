import 'package:flutter/material.dart';

import '../models/study.dart';
import '../ui/glass.dart';
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
        backgroundColor: Tokens.inkRaised,
        title: Text('New chapter', style: Tokens.heading),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: Tokens.body.copyWith(color: Tokens.text),
          decoration: const InputDecoration(hintText: 'Chapter name'),
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
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.chevron_left_rounded,
                color: Tokens.text, size: 30),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text('Study Mode', style: Tokens.heading),
          centerTitle: true,
        ),
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
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Tokens.x6),
                    child: Text(
                      'No chapters yet. Add one to start building notes for '
                      'the Band to read back.',
                      textAlign: TextAlign.center,
                      style: Tokens.body,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                      Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x10),
                  itemCount: chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = chapters[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Tokens.x3),
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
                            color: Tokens.danger.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(Tokens.rMedium),
                          ),
                          child: const Icon(Icons.delete_outline_rounded,
                              color: Tokens.danger),
                        ),
                        child: GlassSurface(
                          radius: Tokens.rMedium,
                          onTap: () => _openChapter(index),
                          padding: const EdgeInsets.symmetric(
                              horizontal: Tokens.x4, vertical: Tokens.x4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(chapter.name, style: Tokens.heading),
                                    const SizedBox(height: 2),
                                    Text(
                                      chapter.notes.length == 1
                                          ? '1 note'
                                          : '${chapter.notes.length} notes',
                                      style: Tokens.label,
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right_rounded,
                                  color: Tokens.textFaint),
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
        floatingActionButton: FloatingActionButton(
          onPressed: _addChapter,
          backgroundColor: Tokens.text,
          child: const Icon(Icons.add_rounded, color: Colors.white),
        ),
      ),
    );
  }
}
