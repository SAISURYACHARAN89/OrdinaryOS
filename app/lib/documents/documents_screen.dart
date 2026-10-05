import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/documents.dart';
import '../ui/surface.dart';
import '../ui/tokens.dart';

/// Picks a PDF and returns its path and file name, or null if cancelled.
typedef PdfPicker = Future<({String path, String name})?> Function();

/// The PDFs Ordinary can answer from: add one, see what is there, remove one.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, required this.library, this.picker});

  final DocumentLibrary library;

  /// Replaced in tests; the system file picker otherwise.
  final PdfPicker? picker;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  bool _adding = false;

  static Future<({String path, String name})?> _systemPicker() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    final file = picked.isEmpty ? null : picked.first;
    final path = file?.path;
    if (file == null || path == null) return null;
    return (path: path, name: file.name);
  }

  void _say(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _add() async {
    if (_adding) return;
    ({String path, String name})? picked;
    try {
      picked = await (widget.picker ?? _systemPicker)();
    } catch (_) {
      if (mounted) _say('The file picker could not be opened.');
      return;
    }
    if (picked == null || !mounted) return;

    setState(() => _adding = true);
    try {
      final added = await widget.library.add(picked.path, fileName: picked.name);
      if (mounted) _say('Added "${added.name}". Ask Ordinary about it.');
    } on DocumentImportError catch (error) {
      if (mounted) _say(error.message);
    } catch (_) {
      if (mounted) _say('That PDF could not be added.');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _remove(DocumentInfo document) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${document.name}"?', style: Tokens.heading),
        content: Text(
          'Ordinary will no longer be able to answer from it. The original '
          'file is not affected.',
          style: Tokens.body.copyWith(fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Remove',
                style: Tokens.bodyStrong.copyWith(color: Tokens.danger)),
          ),
        ],
      ),
    );
    if (yes ?? false) await widget.library.remove(document.id);
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: screenBar(context, text: 'Documents'),
        body: AnimatedBuilder(
          animation: library,
          builder: (context, _) {
            final documents = library.documents;
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                  Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x10),
              children: [
                Text(
                  'Add PDFs and ask Ordinary about them: "Hey Ordinary, what '
                  'does my lease say about the deposit?"',
                  style: Tokens.body.copyWith(fontSize: 15),
                ),
                const SizedBox(height: Tokens.x2),
                Text(
                  'Documents stay on this phone. Only the few lines needed for '
                  'an answer are sent when you ask.',
                  style: Tokens.caption.copyWith(fontSize: 13),
                ),
                const SizedBox(height: Tokens.x5),
                InkButton(
                  label: _adding ? 'Reading the PDF…' : 'Add a PDF',
                  onPressed: _adding ? null : _add,
                ),
                const SizedBox(height: Tokens.x5),
                if (documents.isEmpty)
                  const EmptyNote('No documents yet.')
                else
                  for (final document in documents)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Tokens.x2),
                      child: Surface(
                        radius: 18,
                        padding: const EdgeInsets.fromLTRB(
                            Tokens.x4, Tokens.x3, Tokens.x2, Tokens.x3),
                        child: Row(
                          children: [
                            const Icon(Icons.description_outlined,
                                size: 22, color: Tokens.text),
                            const SizedBox(width: Tokens.x3),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(document.name,
                                      style: Tokens.bodyStrong,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${document.pages} '
                                    '${document.pages == 1 ? 'page' : 'pages'} · added '
                                    '${document.addedAt.day} ${_months[document.addedAt.month - 1]}',
                                    style: Tokens.caption.copyWith(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove ${document.name}',
                              icon: const Icon(Icons.delete_outline_rounded,
                                  size: 20, color: Tokens.textFaint),
                              onPressed: () => _remove(document),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}
