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

      // Stream-bearing abstract contract: an interface with a runtime
      // wrapper (streams marshal as AsyncIterable since Phase 4).
      final repository = api.classByName('NoteRepository')!;
      expect(repository.isAbstract, isTrue);
      expect(repository.methods.map((m) => m.name), [
        'getByTitle',
        'watchAll',
        'save',
      ]);

      // Abstract classes have no factory, so no runtime export of their own.
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

    test('facade matches golden (firestore-types)', () {
      _expectGolden(
        generateFacade(
          firestoreApi,
          globalExportKey: '__dtb_exports_boundary_logic__',
          dateTimeMode: DateTimeMode.firestoreTimestamp,
          firestoreTypes: true,
        ),
        'boundary_logic/facade.firestore-types.dart',
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

    test('.d.ts matches golden (firestore-types)', () {
      _expectGolden(
        generateDts(firestoreApi, firestoreTypes: true),
        'boundary_logic/index.firestore-types.d.ts',
        update: update,
      );
    });
  });

  _phase34Groups(update);
}

void _phase34Groups(bool update) {
  group('oop_logic', () {
    late ApiModel api;

    setUpAll(() async {
      ensureFixtureResolved('oop_logic');
      api = await analyzePackage(readTargetPackage(fixturePath('oop_logic')));
    });

    test('api model shape', () {
      expect(api.enums.map((e) => e.name), ['Priority', 'Signal']);
      expect(api.enumByName('Signal')!.values, ['red', 'amber', 'green']);
      // Enhanced-enum members stay Dart-side; values still cross.
      expect(api.enumByName('Priority')!.values, ['low', 'high']);

      final puppy = api.classByName('Puppy')!;
      expect(puppy.extendsNames, ['Dog']);
      // Own: the override; inherited: Dog's members (incl. mixin-flattened).
      expect(puppy.methods.map((m) => m.name), ['speak']);
      expect(
        puppy.inheritedMethods.map((m) => m.name),
        containsAll(['fetch', 'tag']),
      );
      expect(
        puppy.inheritedProperties.map((f) => f.name),
        containsAll(['name', 'tags']),
      );

      final dog = api.classByName('Dog')!;
      expect(dog.extendsNames, ['Animal']);
      // Mixin members fold into the class's OWN interface body.
      expect(dog.methods.map((m) => m.name), containsAll(['speak', 'tag']));
      expect(api.directSubclassesOf('Dog').map((c) => c.name), ['Puppy']);
      expect(api.directSubclassesOf('Animal').map((c) => c.name), ['Dog']);
    });

    test('facade matches golden', () {
      _expectGolden(
        generateFacade(api, globalExportKey: '__dtb_exports_oop_logic__'),
        'oop_logic/facade.dart',
        update: update,
      );
    });

    test('.d.ts matches golden', () {
      _expectGolden(generateDts(api), 'oop_logic/index.d.ts', update: update);
    });
  });

  group('async_logic', () {
    late ApiModel api;

    setUpAll(() async {
      ensureFixtureResolved('async_logic');
      api = await analyzePackage(readTargetPackage(fixturePath('async_logic')));
    });

    test('api model shape', () {
      final feed = api.classByName('TicketFeed')!;
      expect(feed.isAbstract, isTrue);
      expect(feed.methods.map((m) => m.name), ['watch', 'close']);
      expect(feed.methods.first.returnType, isA<StreamType>());
      expect(
        api.functions
            .firstWhere((f) => f.name == 'applyTwice')
            .parameters[1]
            .type,
        isA<CallbackType>(),
      );
    });

    test('facade matches golden', () {
      _expectGolden(
        generateFacade(api, globalExportKey: '__dtb_exports_async_logic__'),
        'async_logic/facade.dart',
        update: update,
      );
    });

    test('.d.ts matches golden', () {
      _expectGolden(generateDts(api), 'async_logic/index.d.ts', update: update);
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
