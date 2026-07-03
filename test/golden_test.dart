/// Golden-file tests: for each fixture, the generated facade and `.d.ts`
/// must match the checked-in expected output byte for byte.
///
/// Regenerate with: UPDATE_GOLDENS=1 dart test test/golden_test.dart
library;

import 'dart:io';

import 'package:dart_typescript_builder/dart_typescript_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  final update = Platform.environment['UPDATE_GOLDENS'] == '1';

  group('hello_logic', () {
    late ApiModel api;

    setUpAll(() async {
      ensureFixtureResolved('hello_logic');
      api = await analyzePackage(readTargetPackage(fixturePath('hello_logic')));
    });

    test('api model shape', () {
      expect(api.dartPackageName, 'hello_logic');
      expect(api.functions.map((f) => f.name), [
        'add',
        'greet',
        'half',
        'isEven',
      ]);
      expect(api.classes.map((c) => c.name), ['Counter']);
      final counter = api.classes.single;
      expect(counter.factoryName, 'createCounter');
      expect(counter.properties.map((f) => f.name), ['label', 'count']);
      expect(counter.properties.first.isReadonly, isTrue); // final label
      expect(counter.properties.last.isReadonly, isFalse); // mutable count
      expect(counter.methods.map((m) => m.name), [
        'increment',
        'describe',
        'clear',
      ]);
    });

    test('facade matches golden', () {
      _expectGolden(
        generateFacade(api, globalExportKey: '__dtb_exports_hello_logic__'),
        'hello_logic/facade.dart',
        update: update,
      );
    });

    test('.d.ts matches golden', () {
      _expectGolden(generateDts(api), 'hello_logic/index.d.ts', update: update);
    });
  });

  group('boundary_logic', () {
    late ApiModel api;
    late ApiModel firestoreApi;

    setUpAll(() async {
      ensureFixtureResolved('boundary_logic');
      final target = readTargetPackage(fixturePath('boundary_logic'));
      api = await analyzePackage(target);
      firestoreApi = await analyzePackage(
        target,
        dateTimeMode: DateTimeMode.firestoreTimestamp,
      );
    });

    test('api model shape', () {
      expect(api.constants.map((c) => c.name), ['kDefaultLimit', 'kLocales']);
      expect(api.classes.map((c) => c.name), [
        'Note',
        'NoteRepository',
        'Notebook',
      ]);

      final note = api.classByName('Note')!;
      expect(note.isAbstract, isFalse);
      expect(note.isTypeOnly, isFalse);
      expect(note.staticCallables.map((s) => s.name), [
        'fromMap',
        'listFromMaps',
      ]);
      expect(note.staticProperties.map((s) => s.name), ['template']);
      expect(note.constructorParameters.map((c) => c.kind), [
        ParameterKind.requiredPositional,
        ParameterKind.named,
        ParameterKind.named,
      ]);

      // Stream-bearing abstract contract: exported as a type-only interface.
      final repository = api.classByName('NoteRepository')!;
      expect(repository.isAbstract, isTrue);
      expect(repository.isTypeOnly, isTrue);
      expect(repository.methods.map((m) => m.name), [
        'getByTitle',
        'watchAll',
        'save',
      ]);

      // Type-only classes never appear in the runtime exports.
      expect(api.exportedNames, isNot(contains('NoteRepository')));
      expect(
        api.exportedNames,
        containsAll(['createNote', 'Note', 'createNotebook']),
      );

      // DateTime mode changes only the TS spelling.
      expect(api.usesFirestoreTimestamp, isFalse);
      expect(firestoreApi.usesFirestoreTimestamp, isTrue);
    });

    test('facade matches golden (js-date)', () {
      _expectGolden(
        generateFacade(api, globalExportKey: '__dtb_exports_boundary_logic__'),
        'boundary_logic/facade.dart',
        update: update,
      );
    });

    test('facade matches golden (firestore)', () {
      _expectGolden(
        generateFacade(
          firestoreApi,
          globalExportKey: '__dtb_exports_boundary_logic__',
          dateTimeMode: DateTimeMode.firestoreTimestamp,
        ),
        'boundary_logic/facade.firestore.dart',
        update: update,
      );
    });

    test('.d.ts matches golden (js-date)', () {
      _expectGolden(
        generateDts(api),
        'boundary_logic/index.d.ts',
        update: update,
      );
    });

    test('.d.ts matches golden (firestore)', () {
      _expectGolden(
        generateDts(firestoreApi),
        'boundary_logic/index.firestore.d.ts',
        update: update,
      );
    });
  });
}

void _expectGolden(String actual, String goldenName, {required bool update}) {
  final golden = File(p.join('test', 'goldens', goldenName));
  if (update) {
    golden
      ..createSync(recursive: true)
      ..writeAsStringSync(actual);
    return;
  }
  expect(
    golden.existsSync(),
    isTrue,
    reason: 'missing golden $goldenName — run UPDATE_GOLDENS=1 dart test',
  );
  expect(actual, golden.readAsStringSync(), reason: 'golden: $goldenName');
}
