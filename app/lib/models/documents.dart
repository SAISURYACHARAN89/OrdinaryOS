import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../session.dart';

/// A PDF the person has added.
class DocumentInfo {
  const DocumentInfo({
    required this.id,
    required this.name,
    required this.pages,
    required this.passages,
    required this.addedAt,
  });

  final String id;
  final String name;
  final int pages;
  final int passages;
  final DateTime addedAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'pages': pages,
        'passages': passages,
        'addedAt': addedAt.toIso8601String(),
      };

  static DocumentInfo fromJson(Map<String, dynamic> json) => DocumentInfo(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Document',
        pages: (json['pages'] as num?)?.toInt() ?? 0,
        passages: (json['passages'] as num?)?.toInt() ?? 0,
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// A stretch of one page, small enough to hand to Ordinary whole.
class Passage {
  const Passage({required this.document, required this.page, required this.text});

  final String document;
  final int page;
  final String text;
}

/// Why a PDF could not be added, in words for the person.
class DocumentImportError implements Exception {
  DocumentImportError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The text of each page of the PDF at [path], in order.
typedef PdfTextReader = Future<List<String>> Function(String path);

/// The person's PDFs, searchable by Ordinary.
///
/// Everything stays on this phone: the text is pulled out of the PDF here,
/// split into short passages, and searched here. Ordinary is only ever handed
/// the two or three passages a question needs — never the document — because
/// a live session re-bills everything in it on every turn.
class DocumentLibrary extends ChangeNotifier {
  DocumentLibrary({PdfTextReader? reader, Future<Directory> Function()? directory})
      : _read = reader ?? _readWithPdfium,
        _directory = directory ?? _defaultDirectory;

  final PdfTextReader _read;
  final Future<Directory> Function() _directory;

  static const maxDocuments = 20;
  static const maxPages = 600;
  static const maxBytes = 40 * 1024 * 1024;

  /// About this many words to a passage, overlapping the next by a few so a
  /// sentence split across two is still found whole in one of them.
  static const _passageWords = 130;
  static const _overlapWords = 25;

  bool loaded = false;
  final List<DocumentInfo> _documents = [];
  List<DocumentInfo> get documents => List.unmodifiable(_documents);

  /// Names for the session request, so Ordinary knows what there is to search.
  List<String> get titles => [for (final d in _documents) d.name];

  _Index? _index;

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory('${base.path}/documents');
  }

  Future<Directory> _dir() async {
    final dir = await _directory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> load() async {
    try {
      final file = File('${(await _dir()).path}/index.json');
      if (file.existsSync()) {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        _documents
          ..clear()
          ..addAll(list.map((d) => DocumentInfo.fromJson(d as Map<String, dynamic>)));
      }
    } catch (_) {
      // A damaged index is treated as no documents; the files stay on disk.
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _saveIndex() async {
    final file = File('${(await _dir()).path}/index.json');
    await file.writeAsString(jsonEncode([for (final d in _documents) d.toJson()]));
  }

  // ----------------------------------------------------------------- import

  /// Adds the PDF at [path]. Throws [DocumentImportError] with a sentence the
  /// person can act on when it cannot be used.
  Future<DocumentInfo> add(String path, {required String fileName}) async {
    if (_documents.length >= maxDocuments) {
      throw DocumentImportError(
          'You can keep up to $maxDocuments documents. Remove one to add another.');
    }
    final file = File(path);
    if (!file.existsSync()) throw DocumentImportError('That file could not be opened.');
    if (file.lengthSync() > maxBytes) {
      throw DocumentImportError('That PDF is too large. The limit is 40 MB.');
    }

    final List<String> pages;
    try {
      pages = await _read(path);
    } catch (error) {
      // The kind of failure only — never the file's name or contents.
      OrdiBackend.diag('doc-read-failed', '${error.runtimeType}');
      throw DocumentImportError(
          'That PDF could not be read. It may be password-protected or damaged.');
    }
    if (pages.isEmpty) throw DocumentImportError('That PDF has no pages.');
    if (pages.length > maxPages) {
      throw DocumentImportError(
          'That PDF has ${pages.length} pages. The limit is $maxPages.');
    }

    final passages = <Map<String, Object?>>[];
    var letters = 0;
    for (var i = 0; i < pages.length; i++) {
      final text = tidy(pages[i]);
      letters += text.length;
      for (final piece in split(text)) {
        passages.add({'p': i + 1, 't': piece});
      }
    }
    // A scan is pictures of pages: there is nothing in it to search.
    if (letters < pages.length * 40 || passages.isEmpty) {
      throw DocumentImportError(
          'This PDF is a scan, with no text in it to search. Ordinary can only '
          'read PDFs with selectable text for now.');
    }

    final name = _titleFrom(fileName);
    final random = Random.secure();
    final id = List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final info = DocumentInfo(
      id: id,
      name: _unique(name),
      pages: pages.length,
      passages: passages.length,
      addedAt: DateTime.now(),
    );
    await File('${(await _dir()).path}/$id.json').writeAsString(jsonEncode(passages));
    OrdiBackend.diag('doc-added', {'pages': pages.length, 'passages': passages.length});
    _documents.insert(0, info);
    _index = null;
    await _saveIndex();
    notifyListeners();
    return info;
  }

  Future<void> remove(String id) async {
    _documents.removeWhere((d) => d.id == id);
    _index = null;
    try {
      final file = File('${(await _dir()).path}/$id.json');
      if (file.existsSync()) await file.delete();
    } catch (_) {}
    await _saveIndex();
    notifyListeners();
  }

  static String _titleFrom(String fileName) {
    var name = fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    name = name.replaceAll(RegExp(r'[_]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) name = 'Document';
    return name.length > 60 ? name.substring(0, 60).trim() : name;
  }

  String _unique(String name) {
    final taken = {for (final d in _documents) d.name};
    if (!taken.contains(name)) return name;
    for (var n = 2;; n++) {
      if (!taken.contains('$name ($n)')) return '$name ($n)';
    }
  }

  // ------------------------------------------------------------------- text

  /// Page text as it comes out of a PDF: lines broken mid-sentence, words
  /// hyphenated across them, runs of spaces. Returns flowing text.
  @visibleForTesting
  static String tidy(String raw) {
    return raw
        .replaceAll('\r', '\n')
        .replaceAllMapped(RegExp(r'(\p{L})-\n(\p{Ll})', unicode: true),
            (m) => '${m[1]}${m[2]}')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Splits one page into passages of about [_passageWords] words, breaking at
  /// the end of a sentence where there is one nearby.
  @visibleForTesting
  static List<String> split(String text) {
    final words = text.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    if (words.length <= _passageWords + _overlapWords) return [words.join(' ')];

    final out = <String>[];
    var start = 0;
    while (start < words.length) {
      var end = min(start + _passageWords, words.length);
      if (end < words.length) {
        // Prefer to stop at a full stop within the last fifth of the passage.
        for (var i = end; i > end - _passageWords ~/ 5; i--) {
          if (RegExp(r'[.!?।]$').hasMatch(words[i - 1])) {
            end = i;
            break;
          }
        }
      }
      out.add(words.sublist(start, end).join(' '));
      if (end >= words.length) break;
      // Too small a tail is folded into the passage before it instead.
      if (words.length - end < _overlapWords) {
        out[out.length - 1] = words.sublist(start).join(' ');
        break;
      }
      start = end - _overlapWords;
    }
    return out;
  }

  // ----------------------------------------------------------------- search

  /// The passages that best match [query], best first. Empty when nothing
  /// matches at all.
  Future<List<Passage>> search(String query, {int limit = 3}) async {
    if (_documents.isEmpty) return const [];
    final index = _index ??= await _buildIndex();
    return index.search(query, limit: limit);
  }

  Future<_Index> _buildIndex() async {
    final dir = await _dir();
    final index = _Index();
    for (final doc in _documents) {
      try {
        final file = File('${dir.path}/${doc.id}.json');
        if (!file.existsSync()) continue;
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        for (final p in list) {
          index.add(Passage(
            document: doc.name,
            page: ((p as Map)['p'] as num).toInt(),
            text: p['t'] as String,
          ));
        }
      } catch (_) {
        // One unreadable file should not hide the others.
      }
    }
    index.finish();
    return index;
  }

  /// What Ordinary gets back from `search_documents`: up to three passages
  /// with where each came from, held to a size that keeps the turn cheap.
  Future<Map<String, Object?>> toolResult(String query) async {
    final found = await search(query);
    if (found.isEmpty) {
      return {
        'results': const <Object>[],
        'note': _documents.isEmpty
            ? 'They have no documents in the app.'
            : 'Nothing in their documents matches. Try other key words once, '
                'then say you could not find it in their documents.',
      };
    }
    return {
      'results': [
        for (final p in found)
          {
            'document': p.document,
            'page': p.page,
            'text': p.text.length > 1100 ? '${p.text.substring(0, 1100)}…' : p.text,
          },
      ],
    };
  }

  static Future<List<String>> _readWithPdfium(String path) async {
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openFile(path);
    try {
      final pages = <String>[];
      for (final page in document.pages) {
        final text = await page.loadText();
        pages.add(text?.fullText ?? '');
      }
      return pages;
    } finally {
      await document.dispose();
    }
  }
}

/// Keyword search over every passage, ranked the way search engines rank
/// (BM25): words that are rare across the library count for more, and a
/// passage is not favoured just for being long.
class _Index {
  final List<Passage> _passages = [];
  final List<int> _lengths = [];
  final Map<String, List<(int, int)>> _postings = {};
  final Map<String, Set<String>> _titleTerms = {};
  double _averageLength = 1;

  static final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  static const _stop = {
    'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'is', 'are',
    'was', 'were', 'be', 'it', 'its', 'this', 'that', 'with', 'as', 'at', 'by',
    'from', 'what', 'which', 'who', 'how', 'does', 'do', 'did', 'my', 'me', 'i',
    'about', 'say', 'says', 'tell', 'can', 'you', 'your', 'there', 'any',
    'document', 'documents', 'pdf', 'notes', 'file',
  };

  static List<String> terms(String text) {
    final out = <String>[];
    for (final match in _word.allMatches(text.toLowerCase())) {
      var term = match[0]!;
      if (term.length < 2 || _stop.contains(term)) continue;
      // Plural and singular should find each other.
      if (term.length > 3 && term.endsWith('s') && !term.endsWith('ss')) {
        term = term.substring(0, term.length - 1);
      }
      out.add(term);
    }
    return out;
  }

  void add(Passage passage) {
    final index = _passages.length;
    _passages.add(passage);
    final counts = <String, int>{};
    final words = terms(passage.text);
    for (final term in words) {
      counts[term] = (counts[term] ?? 0) + 1;
    }
    _lengths.add(words.length);
    counts.forEach((term, n) => (_postings[term] ??= []).add((index, n)));
    _titleTerms.putIfAbsent(passage.document, () => terms(passage.document).toSet());
  }

  void finish() {
    if (_lengths.isNotEmpty) {
      _averageLength = max(1, _lengths.reduce((a, b) => a + b) / _lengths.length);
    }
  }

  List<Passage> search(String query, {required int limit}) {
    final wanted = terms(query).toSet();
    if (wanted.isEmpty || _passages.isEmpty) return const [];
    const k1 = 1.2;
    const b = 0.75;
    final scores = <int, double>{};
    for (final term in wanted) {
      final postings = _postings[term];
      if (postings == null) continue;
      final idf = log(1 + (_passages.length - postings.length + 0.5) / (postings.length + 0.5));
      for (final (index, count) in postings) {
        final norm = count + k1 * (1 - b + b * _lengths[index] / _averageLength);
        scores[index] = (scores[index] ?? 0) + idf * count * (k1 + 1) / norm;
      }
    }
    if (scores.isEmpty) return const [];
    // "…in my rental agreement": naming a document favours its passages.
    scores.updateAll((index, score) {
      final title = _titleTerms[_passages[index].document] ?? const {};
      final named = wanted.where(title.contains).length;
      return score * (1 + 0.35 * named);
    });
    final ranked = scores.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
    return [for (final entry in ranked.take(limit)) _passages[entry.key]];
  }
}
