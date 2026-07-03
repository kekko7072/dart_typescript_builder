/// End-to-end proof (the "definition of done"): build fixtures with each
/// engine, `npm install` the result into a small TypeScript project, verify
/// `tsc` type-checks the usage (and rejects bad usage), and run it under
/// Node asserting runtime results.
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:dart_typescript_builder/dart_typescript_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

// ---------------------------------------------------------------------------
// hello_logic (Phase 1 surface)
// ---------------------------------------------------------------------------

const _helloConsumerTs = '''
import { add, greet, half, isEven, createCounter, Counter } from "hello-logic";

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(label + ": expected " + expected + ", got " + actual);
  }
}

assertEqual(add(2, 3), 5, "add");
assertEqual(greet("Francesco"), "Hello, Francesco!", "greet");
assertEqual(half(5), 2.5, "half");
assertEqual(isEven(4), true, "isEven");

const c: Counter = createCounter("clicks", 1);
assertEqual(c.label, "clicks", "label");
assertEqual(c.count, 1, "count");
assertEqual(c.increment(4), 5, "increment");
c.count = 10;
assertEqual(c.describe(), "clicks: 10", "describe");
c.clear();
assertEqual(c.count, 0, "clear");

console.log("ALL_ASSERTIONS_PASSED");
''';

// Must NOT type-check: wrong argument type, assignment to readonly property.
const _helloBadConsumerTs = '''
import { add, createCounter } from "hello-logic";

add("two", 3);
const c = createCounter("x", 0);
c.label = "renamed";
''';

// ---------------------------------------------------------------------------
// boundary_logic (Phase 2 surface, js-date mode)
// ---------------------------------------------------------------------------

const _boundaryConsumerTs = '''
import {
  kDefaultLimit, kLocales, sum, shout, lengths, annotate,
  delayedGreet, doubleEventually, addDays, maybeLength, pad, repeat,
  createNote, createNotebook, Note, Notebook, NoteRepository,
} from "boundary-logic";

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(label + ": expected " + expected + ", got " + actual);
  }
}

async function main(): Promise<void> {
  assertEqual(kDefaultLimit, 10, "kDefaultLimit");
  assertEqual(kLocales.join(","), "en,it", "kLocales");
  assertEqual(sum([1, 2, 3]), 6, "sum");
  assertEqual(shout(["a", null, "b"]).join("|"), "A||B", "shout");
  assertEqual(lengths(["ciao", "hi"]).ciao, 4, "lengths");
  const annotated = annotate({ a: 1 }) as Record<string, unknown>;
  assertEqual(annotated.seen, true, "annotate");
  assertEqual(annotate(7), 7, "annotate passthrough");
  assertEqual(await delayedGreet("F", 5), "Hello, F!", "delayedGreet");
  assertEqual(await doubleEventually(Promise.resolve(21)), 42, "doubleEventually");
  const d: Date = addDays(new Date(1720000000000), 1);
  assertEqual(d.getTime(), 1720000000000 + 86400000, "addDays");
  assertEqual(maybeLength("ciao"), 4, "maybeLength");
  assertEqual(maybeLength(null), null, "maybeLength null");
  assertEqual(pad("7", { width: 3 }), "..7", "pad");
  assertEqual(pad("7", { width: 3, fill: "0" }), "007", "pad fill");
  assertEqual(repeat("ab"), "abab", "repeat default");
  assertEqual(repeat("ab", 3), "ababab", "repeat");

  const note: Note = createNote("groceries", {
    createdAt: new Date(0),
    tags: ["home"],
  });
  note.title = "food";
  assertEqual(note.tag("urgent").title, "food", "tag chain");
  assertEqual(note.tag("x") === note, true, "handle identity");
  const map = note.toMap();
  assertEqual((map.tags as string[]).length, 3, "toMap tags");

  const nb: Notebook = createNotebook("main");
  nb.add(note);
  const found: Note | null = nb.find("food");
  assertEqual(found === note, true, "identity through collections");
  assertEqual(nb.find("nope"), null, "find null");
  const loaded: Note[] = await nb.load();
  assertEqual(loaded.length, 1, "load");

  const rebuilt: Note = Note.fromMap({
    title: "t",
    createdAt: new Date(0),
    tags: [],
  });
  assertEqual(rebuilt.title, "t", "static fromMap");
  const many: Note[] = Note.listFromMaps([note.toMap(), rebuilt.toMap()]);
  assertEqual(many.length, 2, "listFromMaps");
  assertEqual(typeof Note.template.title, "string", "live static getter");

  // The Stream-bearing contract exists purely as a TS interface: implement
  // it TS-side with AsyncIterable.
  const repo: NoteRepository = {
    getByTitle: async (title: string) => nb.find(title),
    watchAll: async function* () {
      yield nb.all();
    },
    save: async () => {},
  };
  const got = await repo.getByTitle("food");
  assertEqual(got === note, true, "TS-implemented contract");

  console.log("ALL_ASSERTIONS_PASSED");
}

void main();
''';

// Must NOT type-check: wrong element type, missing required option,
// readonly write.
const _boundaryBadConsumerTs = '''
import { sum, pad, createNote } from "boundary-logic";

sum(["not", "numbers"]);
pad("x", {});
const n = createNote("t", { createdAt: new Date(0) });
n.createdAt = new Date(1);
''';

// ---------------------------------------------------------------------------
// boundary_logic in firestore mode (DateTime <-> firebase-admin Timestamp)
// ---------------------------------------------------------------------------

const _firestoreConsumerTs = '''
import { Timestamp } from "firebase-admin/firestore";
import { addDays, createNote, Note } from "boundary-logic";

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(label + ": expected " + expected + ", got " + actual);
  }
}

const later: Timestamp = addDays(new Timestamp(1720000000, 123456000), 1);
assertEqual(later.seconds, 1720000000 + 86400, "addDays seconds");
assertEqual(later.nanoseconds, 123456000, "microsecond fidelity");

const note: Note = createNote("n", { createdAt: Timestamp.fromMillis(9000) });
const round: Note = Note.fromMap(note.toMap());
assertEqual(round.createdAt.toMillis(), 9000, "toMap/fromMap round trip");
assertEqual(note.toMap().createdAt instanceof Timestamp, true, "dynamic map");

console.log("ALL_ASSERTIONS_PASSED");
''';

// ---------------------------------------------------------------------------
// boundary_logic with --firestore-types (full firebase-admin value set)
// ---------------------------------------------------------------------------

const _firestoreTypesConsumerTs = '''
import {
  Timestamp, GeoPoint, DocumentReference, FieldValue,
} from "firebase-admin/firestore";
import { annotate, createNote, Note } from "boundary-logic";

// Available at runtime under Node; typed by @types/node in real projects.
declare const Buffer: { from(data: number[]): Uint8Array };

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(label + ": expected " + expected + ", got " + actual);
  }
}

const geo = new GeoPoint(45.4, 11.9);
const ref = new DocumentReference({}, "users/u1");
const sentinel = FieldValue.serverTimestamp();
const bytes = new Uint8Array([1, 2, 3]);

const out = annotate({
  location: geo,
  owner: ref,
  updatedAt: sentinel,
  payload: bytes,
  at: Timestamp.fromMillis(9000),
}) as Record<string, unknown>;

assertEqual(out.seen, true, "annotate ran Dart-side");
assertEqual(out.location === geo, true, "GeoPoint identity");
assertEqual(out.owner === ref, true, "DocumentReference identity");
assertEqual(out.updatedAt === sentinel, true, "FieldValue identity");
assertEqual(out.at instanceof Timestamp, true, "Timestamp class");
assertEqual((out.at as Timestamp).toMillis(), 9000, "Timestamp value");
const echoed = out.payload as Uint8Array;
assertEqual(echoed instanceof Uint8Array, true, "bytes class");
assertEqual(echoed === bytes, false, "bytes are a fresh copy");
assertEqual(Array.from(echoed).join(","), "1,2,3", "bytes content");

// Node Buffer (what firebase-admin returns for `bytes` fields) is a
// Uint8Array subclass and must cross the same way.
const viaBuffer = annotate({ b: Buffer.from([7, 8]) }) as
  Record<string, unknown>;
assertEqual(Array.from(viaBuffer.b as Uint8Array).join(","), "7,8",
  "Buffer bytes");

// The values also survive storage inside a Dart object's dynamic map.
const note: Note = createNote("n", { createdAt: Timestamp.fromMillis(0) });
note.meta = { location: geo, updatedAt: sentinel };
assertEqual((note.meta as Record<string, unknown>).location === geo, true,
  "meta GeoPoint identity");
const map = note.toMap() as Record<string, unknown>;
assertEqual((map.meta as Record<string, unknown>).location === geo, true,
  "toMap meta identity");

console.log("ALL_ASSERTIONS_PASSED");
''';

// ---------------------------------------------------------------------------
// edge_logic (hostile names, adversarial-review regressions)
// ---------------------------------------------------------------------------

const _edgeConsumerTs = '''
import {
  looksLikeDart, blockDocumented, count, addOne, cyclic,
  createFoo, createCacheFoo, createShape, Foo, Shape,
} from "edge-logic";

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(label + ": expected " + expected + ", got " + actual);
  }
}

const f: Foo = createFoo(2);
assertEqual(f.foo\$wrapper(), "dollar-ok:2", "dollar method");
assertEqual(f.describe({ toString: 40 }), 42, "toString option (hasOwn)");
const pm = f.protoMap();
assertEqual(pm["ok"], 2, "proto map data");
assertEqual(Object.getPrototypeOf(pm) === Object.prototype, true,
  "prototype not polluted");
const s: Shape = createShape(5);
assertEqual(s.describe(), "polygon(5)", "abstract factory ctor");
assertEqual(createCacheFoo(7).y, 7, "CacheFoo vs Foo name collision");
assertEqual(count(3), 6, "reserved-word param");
assertEqual(blockDocumented(1), 2, "block doc");
assertEqual(looksLikeDart("a.dart"), true, "glob doc");
try { cyclic(); throw new Error("cyclic did not throw"); }
catch (e) {
  if (!/cyclic/.test((e as Error).message)) throw e;
}
try { addOne(9007199254740994); throw new Error("addOne did not throw"); }
catch (e) {
  if (!/safe integer/.test((e as Error).message)) throw e;
}
console.log("ALL_ASSERTIONS_PASSED");
''';

// ---------------------------------------------------------------------------
// oop_logic (Phase 3: enums + hierarchies)
// ---------------------------------------------------------------------------

const _oopConsumerTs = '''
import {
  Signal, Priority, nextSignal, parseSignal, prioritize,
  adopt, createDog, createPuppy, createKennel,
  Animal, Dog, Puppy, Kennel,
} from "oop-logic";

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(label + ": expected " + expected + ", got " + actual);
  }
}

const next: Signal = nextSignal("red");
assertEqual(next, "green", "enum round trip");
assertEqual(parseSignal(null), null, "nullable enum");
const priorities: Priority[] = prioritize({ a: true, b: false });
assertEqual(priorities.join(","), "high,low", "enums in collections");

const puppy: Puppy = createPuppy("Bit");
const asAnimal: Animal = puppy; // interface extends compiles
assertEqual(asAnimal.speak(), "yip", "override through supertype");
assertEqual(puppy.fetch(), "Bit fetches!", "inherited Dog member");
puppy.tag("cute");
assertEqual(puppy.tags.join(","), "cute", "mixin member");

const dog: Dog = createDog("Fido");
const kennel: Kennel = createKennel();
kennel.admit(puppy);
kennel.admit(dog);
assertEqual(kennel.chorus().join(","), "yip,woof", "polymorphic chorus");
assertEqual(kennel.residents.length, 2, "supertype collection");

const adopted = adopt("puppy", "Zip") as Puppy;
assertEqual(adopted.speak(), "yip", "runtime dispatch to most-derived");
assertEqual(adopted.fetch(), "Zip fetches!", "dispatched wrapper has Dog API");

console.log("ALL_ASSERTIONS_PASSED");
''';

// Must NOT type-check: invalid enum literal, readonly write.
const _oopBadConsumerTs = '''
import { nextSignal, createPuppy } from "oop-logic";

nextSignal("blue");
const p = createPuppy("x");
p.name = "renamed";
''';

// ---------------------------------------------------------------------------
// async_logic (Phase 3/4: callbacks + runtime streams)
// ---------------------------------------------------------------------------

const _asyncConsumerTs = '''
import {
  applyTwice, greetVia, makeAdder, describeVia,
  counter, total, issueTickets, feedOf,
  createTicket, Ticket, TicketFeed,
} from "async-logic";

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(label + ": expected " + expected + ", got " + actual);
  }
}

async function main(): Promise<void> {
  assertEqual(applyTwice(5, (x: number) => x * 3), 45, "sync callback");
  assertEqual(
    await greetVia(async (name: string) => "Ciao " + name + "!"),
    "Ciao Francesco!",
    "async callback",
  );
  const add7: (value: number) => number = makeAdder(7);
  assertEqual(add7(35), 42, "returned function");

  const ticket: Ticket = createTicket("amperry");
  assertEqual(
    describeVia(ticket, (t: Ticket) => t.describe().toUpperCase()),
    "TICKET FOR AMPERRY",
    "handle in callback",
  );

  const seen: number[] = [];
  for await (const value of counter(4)) seen.push(value);
  assertEqual(seen.join(","), "1,2,3,4", "dart stream for-await");

  const partial: number[] = [];
  for await (const value of counter(100)) {
    partial.push(value);
    if (partial.length === 2) break;
  }
  assertEqual(partial.join(","), "1,2", "early break cancels");

  async function* gen(): AsyncIterable<number> {
    yield 20;
    yield 22;
  }
  assertEqual(await total(gen()), 42, "js async iterable to dart");

  const owners: string[] = [];
  for await (const t of issueTickets(["a", "b"])) owners.push(t.owner);
  assertEqual(owners.join(","), "a,b", "stream of handles");

  const feed: TicketFeed = feedOf(["x", "y", "z"]);
  let count = 0;
  for await (const t of feed.watch()) count += t.owner.length;
  assertEqual(count, 3, "abstract stream contract");
  await feed.close();

  console.log("ALL_ASSERTIONS_PASSED");
}

void main();
''';

void main() {
  final hasNode = _canRun('node', ['--version']);
  final hasNpm = _canRun('npm', ['--version']);
  final hasTsc = _canRun('tsc', ['--version']);
  final toolchain = hasNode && hasNpm && hasTsc;

  Future<BuildResult> build(
    String label,
    String fixture,
    String engine, {
    DateTimeMode dateTimeMode = DateTimeMode.jsDate,
  }) async {
    ensureFixtureResolved(fixture);
    final dist = freshTmpDir('$label/dist');
    final result = await buildNpmPackage(
      BuildOptions(
        packagePath: fixturePath(fixture),
        outputPath: dist.path,
        engine: engine,
        npmPackageName: fixture.replaceAll('_', '-'),
        dateTimeMode: dateTimeMode,
        runNpmInstall: false,
      ),
    );
    for (final file in result.files) {
      expect(
        File(p.join(result.outputDir, file)).existsSync(),
        isTrue,
        reason: 'expected generated file $file',
      );
    }
    return result;
  }

  group('hello_logic / dart2js (commonjs)', () {
    test(
      'build -> npm install -> tsc -> node',
      () async {
        final built = await build('js-cjs', 'hello_logic', 'dart2js');
        expect(built.api.exportedNames, [
          'add',
          'greet',
          'half',
          'isEven',
          'createCounter',
        ]);
        _npmTscNode(
          'js-cjs',
          built,
          esm: false,
          consumerTs: _helloConsumerTs,
          badConsumerTs: _helloBadConsumerTs,
        );
      },
      skip: toolchain ? false : 'needs node, npm and tsc',
    );
  });

  group('hello_logic / dart2js (esm)', () {
    test('build -> node named imports', () async {
      ensureFixtureResolved('hello_logic');
      final dist = freshTmpDir('js-esm/dist');
      final built = await buildNpmPackage(
        BuildOptions(
          packagePath: fixturePath('hello_logic'),
          outputPath: dist.path,
          engine: 'dart2js',
          moduleFormat: ModuleFormat.esm,
          npmPackageName: 'hello-logic',
          // Default: the output is completed as an npm project (no peer
          // deps here, so this stays offline).
        ),
      );
      expect(built.npmInstalled, isTrue);
      expect(
        File(p.join(dist.path, 'package-lock.json')).existsSync(),
        isTrue,
        reason: 'npm install must initialize the output as an npm project',
      );
      final probe = p.join(dist.path, 'smoke.mjs');
      File(probe).writeAsStringSync('''
import { add, createCounter } from "./index.js";
const c = createCounter("x", 40);
if (add(1, 1) !== 2 || c.increment(2) !== 42) throw new Error("boom");
console.log("ESM_OK");
''');
      final run = _runChecked('node', ['smoke.mjs'], dist.path);
      expect(run.stdout, contains('ESM_OK'));
    }, skip: hasNode ? false : 'needs node');
  });

  group('hello_logic / wasm (esm)', () {
    test(
      'build -> npm install -> tsc -> node',
      () async {
        final built = await build('wasm', 'hello_logic', 'wasm');
        _npmTscNode(
          'wasm',
          built,
          esm: true,
          consumerTs: _helloConsumerTs,
          badConsumerTs: _helloBadConsumerTs,
        );
      },
      skip: toolchain ? false : 'needs node, npm and tsc',
    );
  });

  group('boundary_logic / dart2js (commonjs)', () {
    test(
      'build -> npm install -> tsc -> node',
      () async {
        final built = await build('boundary-cjs', 'boundary_logic', 'dart2js');
        _npmTscNode(
          'boundary-cjs',
          built,
          esm: false,
          consumerTs: _boundaryConsumerTs,
          badConsumerTs: _boundaryBadConsumerTs,
        );
      },
      skip: toolchain ? false : 'needs node, npm and tsc',
    );
  });

  group('boundary_logic / wasm (esm)', () {
    test(
      'build -> npm install -> tsc -> node',
      () async {
        final built = await build('boundary-wasm', 'boundary_logic', 'wasm');
        _npmTscNode(
          'boundary-wasm',
          built,
          esm: true,
          consumerTs: _boundaryConsumerTs,
          badConsumerTs: _boundaryBadConsumerTs,
        );
      },
      skip: toolchain ? false : 'needs node, npm and tsc',
    );
  });

  for (final engine in ['dart2js', 'wasm']) {
    final esm = engine == 'wasm';
    group('oop_logic / $engine', () {
      test(
        'enums + hierarchies through npm+tsc+node',
        () async {
          final built = await build('oop-$engine', 'oop_logic', engine);
          _npmTscNode(
            'oop-$engine',
            built,
            esm: esm,
            consumerTs: _oopConsumerTs,
            badConsumerTs: _oopBadConsumerTs,
          );
        },
        skip: toolchain ? false : 'needs node, npm and tsc',
      );
    });

    group('async_logic / $engine', () {
      test(
        'callbacks + runtime streams through npm+tsc+node',
        () async {
          final built = await build('async-$engine', 'async_logic', engine);
          _npmTscNode(
            'async-$engine',
            built,
            esm: esm,
            consumerTs: _asyncConsumerTs,
          );
        },
        skip: toolchain ? false : 'needs node, npm and tsc',
      );
    });
  }

  group('edge_logic / dart2js (commonjs)', () {
    test(
      'hostile names and review regressions survive npm+tsc+node',
      () async {
        final built = await build('edge-cjs', 'edge_logic', 'dart2js');
        _npmTscNode('edge-cjs', built, esm: false, consumerTs: _edgeConsumerTs);
      },
      skip: toolchain ? false : 'needs node, npm and tsc',
    );
  });

  group('boundary_logic / firestore mode', () {
    test(
      'DateTime crosses as firebase-admin Timestamp',
      () async {
        final built = await build(
          'boundary-fs',
          'boundary_logic',
          'dart2js',
          dateTimeMode: DateTimeMode.firestoreTimestamp,
        );
        expect(built.api.usesFirestoreTimestamp, isTrue);
        _npmTscNode(
          'boundary-fs',
          built,
          esm: false,
          consumerTs: _firestoreConsumerTs,
          withFirebaseAdminStub: true,
        );
      },
      skip: toolchain ? false : 'needs node, npm and tsc',
    );
  });

  group('boundary_logic / firestore-types', () {
    for (final engine in ['dart2js', 'wasm']) {
      test(
        '$engine: firebase-admin values cross inside dynamic data',
        () async {
          ensureFixtureResolved('boundary_logic');
          final dist = freshTmpDir('fstypes-$engine/dist');
          final built = await buildNpmPackage(
            BuildOptions(
              packagePath: fixturePath('boundary_logic'),
              outputPath: dist.path,
              engine: engine,
              npmPackageName: 'boundary-logic',
              dateTimeMode: DateTimeMode.firestoreTimestamp,
              firestoreTypes: true,
              runNpmInstall: false,
            ),
          );
          _npmTscNode(
            'fstypes-$engine',
            built,
            esm: engine == 'wasm',
            consumerTs: _firestoreTypesConsumerTs,
            withFirebaseAdminStub: true,
          );
        },
        skip: toolchain ? false : 'needs node, npm and tsc',
      );
    }

    test('is rejected without --datetime firestore', () {
      expect(
        () => buildNpmPackage(
          BuildOptions(
            packagePath: fixturePath('boundary_logic'),
            outputPath: 'unused',
            firestoreTypes: true,
          ),
        ),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            contains('--datetime firestore'),
          ),
        ),
      );
    });
  });

  group('tomorrowtech_user acceptance', () {
    const targetPath =
        '/Users/francescovezzani/Developer/TomorrowTech/software/packages/tomorrowtech_user';
    final available = Directory(targetPath).existsSync();

    for (final engine in ['dart2js', 'wasm']) {
      test(
        '$engine + firestore: fromMap/toMap round trip',
        () async {
          final root = freshTmpDir('ttuser-$engine');
          final dist = Directory(
            p.join(root.path, 'node_modules', 'tomorrowtech-user'),
          )..createSync(recursive: true);
          await buildNpmPackage(
            BuildOptions(
              packagePath: targetPath,
              outputPath: dist.path,
              engine: engine,
              npmPackageName: 'tomorrowtech-user',
              dateTimeMode: DateTimeMode.firestoreTimestamp,
              // Keep the suite offline AND single-copy: a default npm
              // install would fetch the real firebase-admin peer into the
              // package's own node_modules, shadowing the stub written next
              // to it — a second Timestamp class identity.
              runNpmInstall: false,
            ),
          );
          _writeFirebaseAdminStub(p.join(root.path, 'node_modules'));
          final script = p.join(root.path, 'check.mjs');
          File(script).writeAsStringSync(_tomorrowtechCheckMjs);
          final run = _runChecked('node', ['check.mjs'], root.path);
          expect(run.stdout, contains('TOMORROWTECH_USER_OK'));
        },
        skip: available && hasNode ? false : 'needs $targetPath and node',
      );
    }
  });
}

/// Sets up the consumer project, npm-installs the built package, runs tsc
/// (accepting good usage, rejecting bad usage) and executes the compiled
/// consumer under Node.
void _npmTscNode(
  String label,
  BuildResult built, {
  required bool esm,
  required String consumerTs,
  String? badConsumerTs,
  bool withFirebaseAdminStub = false,
}) {
  final consumer = freshTmpDir('$label/consumer');
  File(p.join(consumer.path, 'package.json')).writeAsStringSync('''
{
  "name": "consumer",
  "private": true,
  ${esm ? '"type": "module",' : ''}
  "dependencies": { "${built.npmName}": "file:${built.outputDir}" }
}
''');
  File(p.join(consumer.path, 'tsconfig.json')).writeAsStringSync(
    esm
        ? '''
{
  "compilerOptions": {
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "target": "es2022",
    "strict": true,
    "noEmitOnError": true
  },
  "files": ["consumer.ts"]
}
'''
        : '''
{
  "compilerOptions": {
    "module": "commonjs",
    "moduleResolution": "node",
    "target": "es2020",
    "strict": true,
    "esModuleInterop": true,
    "noEmitOnError": true
  },
  "files": ["consumer.ts"]
}
''',
  );
  File(p.join(consumer.path, 'consumer.ts')).writeAsStringSync(consumerTs);

  _runChecked('npm', [
    'install',
    '--no-audit',
    '--no-fund',
    // Peer dependencies (firebase-admin) are satisfied by the local stub,
    // never from the registry: keeps the suite offline.
    '--legacy-peer-deps',
    // Copy instead of symlinking so the installed package resolves the peer
    // stub from the consumer's node_modules — a single Timestamp class
    // identity, like a real deployment.
    '--install-links',
  ], consumer.path);
  if (withFirebaseAdminStub) {
    _writeFirebaseAdminStub(p.join(consumer.path, 'node_modules'));
  }
  _runChecked('tsc', ['-p', '.'], consumer.path);
  final run = _runChecked('node', ['consumer.js'], consumer.path);
  expect(run.stdout, contains('ALL_ASSERTIONS_PASSED'));

  if (badConsumerTs != null) {
    File(p.join(consumer.path, 'consumer.ts')).writeAsStringSync(badConsumerTs);
    final bad = Process.runSync(
      'tsc',
      ['-p', '.'],
      workingDirectory: consumer.path,
      runInShell: true,
    );
    expect(
      bad.exitCode,
      isNot(0),
      reason:
          'tsc must reject wrong argument types and readonly writes,'
          ' got:\n${bad.stdout}',
    );
    expect(bad.stdout.toString(), contains('consumer.ts'));
  }
}

/// A minimal, faithful offline stub of `firebase-admin/firestore` exposing
/// the `Timestamp` contract (the real package would be fetched from the
/// registry; the boundary only relies on the documented Timestamp API).
void _writeFirebaseAdminStub(String nodeModulesPath) {
  final root = Directory(p.join(nodeModulesPath, 'firebase-admin', 'firestore'))
    ..createSync(recursive: true);
  File(
    p.join(nodeModulesPath, 'firebase-admin', 'package.json'),
  ).writeAsStringSync('''
{
  "name": "firebase-admin",
  "version": "13.0.0-stub",
  "description": "Offline test stub exposing the Timestamp contract.",
  "exports": {
    "./firestore": {
      "types": "./firestore/index.d.ts",
      "default": "./firestore/index.js"
    }
  }
}
''');
  File(p.join(root.path, 'index.js')).writeAsStringSync('''
class Timestamp {
  constructor(seconds, nanoseconds) {
    this._seconds = seconds;
    this._nanoseconds = nanoseconds;
  }
  get seconds() { return this._seconds; }
  get nanoseconds() { return this._nanoseconds; }
  static fromMillis(ms) {
    const seconds = Math.floor(ms / 1000);
    return new Timestamp(seconds, Math.round((ms - seconds * 1000) * 1e6));
  }
  static fromDate(date) { return Timestamp.fromMillis(date.getTime()); }
  static now() { return Timestamp.fromMillis(Date.now()); }
  toMillis() { return this._seconds * 1000 + this._nanoseconds / 1e6; }
  toDate() { return new Date(this.toMillis()); }
  isEqual(other) {
    return other instanceof Timestamp &&
      other._seconds === this._seconds &&
      other._nanoseconds === this._nanoseconds;
  }
}
class GeoPoint {
  constructor(latitude, longitude) {
    this._latitude = latitude;
    this._longitude = longitude;
  }
  get latitude() { return this._latitude; }
  get longitude() { return this._longitude; }
  isEqual(other) {
    return other instanceof GeoPoint &&
      other._latitude === this._latitude &&
      other._longitude === this._longitude;
  }
}
class DocumentReference {
  constructor(firestore, path) {
    this.firestore = firestore ?? {};
    this.path = path;
  }
  get id() {
    const parts = this.path.split("/");
    return parts[parts.length - 1];
  }
  get() { return Promise.reject(new Error("offline stub")); }
  set() { return Promise.reject(new Error("offline stub")); }
  listCollections() { return Promise.resolve([]); }
}
class FieldValue {
  constructor(methodName) { this._methodName = methodName; }
  static serverTimestamp() { return new FieldValue("serverTimestamp"); }
  static increment(n) { return new FieldValue("increment"); }
  static delete() { return new FieldValue("delete"); }
  isEqual(other) {
    return other instanceof FieldValue &&
      other._methodName === this._methodName;
  }
}
// VectorValue is deliberately absent: firebase-admin < 12.2 does not export
// it, and the generated packages must tolerate that.
module.exports = { Timestamp, GeoPoint, DocumentReference, FieldValue };
''');
  File(p.join(root.path, 'index.d.ts')).writeAsStringSync('''
export declare class Timestamp {
  constructor(seconds: number, nanoseconds: number);
  readonly seconds: number;
  readonly nanoseconds: number;
  static fromMillis(milliseconds: number): Timestamp;
  static fromDate(date: Date): Timestamp;
  static now(): Timestamp;
  toMillis(): number;
  toDate(): Date;
  isEqual(other: Timestamp): boolean;
}
export declare class GeoPoint {
  constructor(latitude: number, longitude: number);
  readonly latitude: number;
  readonly longitude: number;
  isEqual(other: GeoPoint): boolean;
}
export declare class DocumentReference {
  constructor(firestore: unknown, path: string);
  readonly firestore: unknown;
  readonly path: string;
  readonly id: string;
  get(): Promise<unknown>;
  set(data: unknown): Promise<unknown>;
  listCollections(): Promise<unknown[]>;
}
export declare class FieldValue {
  static serverTimestamp(): FieldValue;
  static increment(n: number): FieldValue;
  static delete(): FieldValue;
  isEqual(other: FieldValue): boolean;
}
''');
}

const _tomorrowtechCheckMjs = '''
import assert from "node:assert/strict";
import { Timestamp } from "firebase-admin/firestore";
import * as tt from "tomorrowtech-user";

const doc = {
  platform: "app", delete: false, token: "tok-1", locale: "it",
  profileUser: { configured: true, name: "Francesco", surname: "Vezzani", email: "f@example.com" },
  rentingSession: {
    orderId: "", powerBankId: "", powerBankBatteryLevelStart: 0, stationId: "",
    start: Timestamp.fromMillis(1720000000000), resumeClock: false,
    resumeMilliseconds: 0, resumeTimeStopped: Timestamp.fromMillis(1720000000000),
    paymentResume: false, batteryLevel: 0,
  },
  billing: {
    configured: true, customerId: "cus_1",
    wallet: { balance: 250, updated: Timestamp.fromMillis(1719000000000) },
    paymentMethodDefault: "pm_1",
    paymentMethods: [{ active: true, id: "pm_1", brand: "visa", country: "IT", last4: "4242", expirationMonth: 12, expirationYear: 2030 }],
    paymentIntentID: "",
  },
  consents: [{ code: "tos", id: "c1", originalId: "o1" }],
};

const user = tt.UserData.fromMap(doc, { uid: "user-1" });
assert.equal(user.uid, "user-1");
assert.equal(user.profileUser.name, "Francesco");
assert.equal(user.billing.wallet.balance, 250);
assert.ok(user.billing.wallet.updated instanceof Timestamp);
assert.equal(user.billing.paymentMethods[0].last4, "4242");
user.consents[0].code = "privacy";
assert.equal(user.consents[0].code, "privacy");
const out = user.toMap();
assert.ok(out.rentingSession.start instanceof Timestamp);
assert.equal(out.billing.wallet.balance, 250);
assert.equal(tt.Wallet.initialiseJSON.balance, 0);
assert.ok(tt.RentingSession.initialiseJSON.start instanceof Timestamp);
assert.equal(tt.kLocalesIT, "it");
assert.equal(tt.PaymentMethod.listFromMaps(doc)[0].brand, "visa");
console.log("TOMORROWTECH_USER_OK");
''';

bool _canRun(String executable, List<String> args) {
  try {
    return Process.runSync(executable, args, runInShell: true).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

ProcessResult _runChecked(String executable, List<String> args, String cwd) {
  final result = Process.runSync(
    executable,
    args,
    workingDirectory: cwd,
    runInShell: true,
  );
  expect(
    result.exitCode,
    0,
    reason:
        '$executable ${args.join(' ')} failed:\n'
        '${result.stdout}\n${result.stderr}',
  );
  return result;
}
