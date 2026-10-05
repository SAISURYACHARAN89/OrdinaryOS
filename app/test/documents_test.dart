import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ordi/documents/documents_screen.dart';
import 'package:ordi/models/ai_brief.dart';
import 'package:ordi/models/documents.dart';
import 'package:ordi/models/recording_store.dart';
import 'package:ordi/models/reminder_scheduler.dart';
import 'package:ordi/models/speed_dial.dart';
import 'package:ordi/ordi/tool_dispatcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pages of text standing in for PDFs, by path.
const lease = [
  'RENTAL AGREEMENT. This agreement is made between the owner and the tenant '
      'for the flat at 14 Lake Road. The monthly rent is Rs 22,000, payable on '
      'or before the fifth day of each month by bank transfer.',
  'DEPOSIT. The tenant shall pay a refundable security deposit of Rs 50,000 '
      'before moving in. The deposit is returned within thirty days of leaving, '
      'less the cost of any damage beyond ordinary wear.',
  'PETS. Pets are allowed only with written permission from the owner. '
      'NOTICE. Either side may end this agreement with two months of written '
      'notice.',
];
const chemistry = [
  'Chapter 4. Buffers. A buffer solution resists changes in pH when small '
      'amounts of acid or base are added. It is made from a weak acid and its '
      'conjugate base, or a weak base and its conjugate acid.',
  'The Henderson-Hasselbalch equation relates the pH of a buffer to the pKa '
      'of the acid and the ratio of the concentrations of base and acid.',
];

void main() {
  late Directory dir;
  late Map<String, List<String>> pdfs;

  DocumentLibrary make() => DocumentLibrary(
        reader: (path) async => pdfs[path] ?? (throw const FormatException('bad pdf')),
        directory: () async => dir,
      );

  /// A real file for each fake PDF, since the library checks it exists.
  String file(String name, List<String> pages) {
    final path = '${dir.path}/$name';
    File(path).writeAsStringSync('%PDF');
    pdfs[path] = pages;
    return path;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ordinary-docs-');
    pdfs = {};
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('text from a PDF', () {
    test('lines, hyphenated words and stray spaces become flowing text', () {
      expect(
        DocumentLibrary.tidy('The secur-\nity deposit   is\nreturned\r\nwithin thirty days.'),
        'The security deposit is returned within thirty days.',
      );
    });

    test('a short page is one passage; a long one is split with overlap', () {
      expect(DocumentLibrary.split('Just a few words here.'), ['Just a few words here.']);

      final sentence = List.generate(12, (i) => 'word$i').join(' ');
      final page = List.generate(40, (i) => '$sentence end$i.').join(' ');
      final parts = DocumentLibrary.split(page);
      expect(parts.length, greaterThan(2));
      for (final part in parts) {
        expect(part.split(' ').length, lessThanOrEqualTo(160));
      }
      // Each passage but the last stops at the end of a sentence…
      for (final part in parts.take(parts.length - 1)) {
        expect(part.endsWith('.'), isTrue);
      }
      // …and nothing is lost: every sentence ending is in some passage.
      for (var i = 0; i < 40; i++) {
        expect(parts.any((p) => p.contains('end$i.')), isTrue, reason: 'end$i');
      }
      // Neighbours share a few words, so a sentence on the boundary survives.
      final tail = parts[0].split(' ').sublist(parts[0].split(' ').length - 5).join(' ');
      expect(parts[1].contains(tail), isTrue);
    });
  });

  group('the library', () {
    test('adds a PDF, keeps it across a relaunch, and removes it', () async {
      final library = make();
      await library.load();
      expect(library.documents, isEmpty);

      final added = await library.add(file('Rental_Agreement_2026.pdf', lease),
          fileName: 'Rental_Agreement_2026.pdf');
      expect(added.name, 'Rental Agreement 2026');
      expect(added.pages, 3);
      expect(library.titles, ['Rental Agreement 2026']);

      final relaunched = make();
      await relaunched.load();
      expect(relaunched.titles, ['Rental Agreement 2026']);
      expect((await relaunched.search('security deposit')).first.page, 2);

      await relaunched.remove(added.id);
      expect(relaunched.documents, isEmpty);
      expect(File('${dir.path}/${added.id}.json').existsSync(), isFalse);
      expect(await relaunched.search('security deposit'), isEmpty);
    });

    test('refuses a scan, a broken file, and one with too many pages', () async {
      final library = make();
      await library.load();

      await expectLater(
        library.add(file('scan.pdf', ['', ' ', '\n']), fileName: 'scan.pdf'),
        throwsA(isA<DocumentImportError>().having((e) => e.message, 'message', contains('scan'))),
      );
      final broken = '${dir.path}/broken.pdf';
      File(broken).writeAsStringSync('nope');
      await expectLater(
        library.add(broken, fileName: 'broken.pdf'),
        throwsA(isA<DocumentImportError>().having((e) => e.message, 'message', contains('could not be read'))),
      );
      await expectLater(
        library.add(file('huge.pdf', List.filled(601, 'Some text on every page of this one.')), fileName: 'huge.pdf'),
        throwsA(isA<DocumentImportError>().having((e) => e.message, 'message', contains('601 pages'))),
      );
      expect(library.documents, isEmpty);
    });

    test('two files with the same name get distinct titles', () async {
      final library = make();
      await library.load();
      await library.add(file('a/notes.pdf'.replaceAll('/', '_'), chemistry), fileName: 'Notes.pdf');
      final second = await library.add(file('b_notes.pdf', lease), fileName: 'Notes.pdf');
      expect(second.name, 'Notes (2)');
    });
  });

  group('search', () {
    late DocumentLibrary library;
    setUp(() async {
      library = make();
      await library.load();
      await library.add(file('Rental Agreement 2026.pdf', lease), fileName: 'Rental Agreement 2026.pdf');
      await library.add(file('Chemistry Chapter 4.pdf', chemistry), fileName: 'Chemistry Chapter 4.pdf');
    });

    test('finds the passage that answers the question, with its page', () async {
      final deposit = await library.search('security deposit amount');
      expect(deposit.first.document, 'Rental Agreement 2026');
      expect(deposit.first.page, 2);
      expect(deposit.first.text, contains('Rs 50,000'));

      final buffers = await library.search('what is a buffer solution');
      expect(buffers.first.document, 'Chemistry Chapter 4');
      expect(buffers.first.text, contains('resists changes in pH'));
    });

    test('plural and singular find each other; the question words are ignored', () async {
      expect((await library.search('pet')).first.text, contains('Pets are allowed'));
      expect((await library.search('what does my document say about buffers')).first.document,
          'Chemistry Chapter 4');
    });

    test('naming a document favours it', () async {
      final found = await library.search('rental agreement notice');
      expect(found.first.document, 'Rental Agreement 2026');
      expect(found.first.text, contains('two months'));
    });

    test('says so when nothing matches', () async {
      expect(await library.search('photosynthesis chlorophyll'), isEmpty);
      final reply = await library.toolResult('photosynthesis chlorophyll');
      expect(reply['results'], isEmpty);
      expect(reply['note'], contains('could not find'));
    });

    test('hands Ordinary at most three passages, each a bounded size', () async {
      final long = List.generate(30, (i) => 'Clause $i: the deposit and the rent and the notice apply here in full detail and at length. ').join();
      await library.add(file('Long.pdf', List.filled(20, long)), fileName: 'Long.pdf');
      final reply = await library.toolResult('deposit rent notice');
      final results = reply['results'] as List;
      expect(results.length, 3);
      for (final r in results) {
        expect((r as Map)['document'], isA<String>());
        expect(r['page'], isA<int>());
        expect((r['text'] as String).length, lessThanOrEqualTo(1101));
      }
      // The whole reply stays small enough to keep the turn cheap.
      expect(jsonEncode(reply).length, lessThan(4200));
    });
  });

  group('as a tool', () {
    test('search_documents answers from the library; an empty query is refused', () async {
      SharedPreferences.setMockInitialValues({});
      final library = make();
      await library.load();
      await library.add(file('Rental Agreement 2026.pdf', lease), fileName: 'Rental Agreement 2026.pdf');
      final tools = ToolDispatcher(
        brief: AiBrief(),
        recordings: RecordingStore(),
        speedDial: SpeedDial(),
        reminders: ReminderScheduler(speak: (_) async => false),
        documents: library,
      );
      final reply = await tools.handle('search_documents', {'query': 'security deposit'});
      expect(((reply['results'] as List).first as Map)['text'], contains('Rs 50,000'));
      expect((await tools.handle('search_documents', {'query': '  '}))['error'], isNotNull);
    });

    test('current_time reads the phone clock', () async {
      SharedPreferences.setMockInitialValues({});
      final tools = ToolDispatcher(
        brief: AiBrief(),
        recordings: RecordingStore(),
        speedDial: SpeedDial(),
        reminders: ReminderScheduler(speak: (_) async => false),
      );
      final before = DateTime.now();
      final reply = await tools.handle('current_time', {});
      expect(reply['time'], matches(RegExp(r'^(1[0-2]|[1-9]):[0-5]\d (AM|PM)$')));
      expect(reply['date'], contains('${before.year}'));
      expect(reply['date'], matches(RegExp(r'^[A-Z][a-z]+day \d{1,2} [A-Z][a-z]+ \d{4}$')));
    });
  });

  /// File reads and writes only finish in real time, a turn at a time.
  Future<void> io(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 5)); // let the confirmation fade
  }

  group('the Documents screen', () {
    testWidgets('adds a PDF, lists it, and removes it', (tester) async {
      final library = make();
      await tester.runAsync(library.load);
      final path = file('Rental Agreement 2026.pdf', lease);

      await tester.pumpWidget(MaterialApp(
        home: DocumentsScreen(
          library: library,
          picker: () async => (path: path, name: 'Rental Agreement 2026.pdf'),
        ),
      ));
      expect(find.text('No documents yet.'), findsOneWidget);

      await tester.tap(find.text('Add a PDF'));
      await io(tester);
      expect(find.text('Rental Agreement 2026'), findsOneWidget);
      expect(find.textContaining('3 pages'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await io(tester);
      expect(find.text('No documents yet.'), findsOneWidget);
    });

    testWidgets('explains why a scanned PDF was not added', (tester) async {
      final library = make();
      await tester.runAsync(library.load);
      final path = file('scan.pdf', ['', '']);

      await tester.pumpWidget(MaterialApp(
        home: DocumentsScreen(
          library: library,
          picker: () async => (path: path, name: 'scan.pdf'),
        ),
      ));
      await tester.tap(find.text('Add a PDF'));
      await io(tester);
      expect(find.textContaining('This PDF is a scan'), findsOneWidget);
      expect(find.text('No documents yet.'), findsOneWidget);
    });
  });
}
