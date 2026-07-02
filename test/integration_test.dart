/// End-to-end proof (the "definition of done"): build the fixture with each
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

const _consumerTs = '''
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
const _badConsumerTs = '''
import { add, createCounter } from "hello-logic";

add("two", 3);
const c = createCounter("x", 0);
c.label = "renamed";
''';

void main() {
  final hasNode = _canRun('node', ['--version']);
  final hasNpm = _canRun('npm', ['--version']);
  final hasTsc = _canRun('tsc', ['--version']);

  Future<BuildResult> build(String label, String engine) async {
    ensureFixtureResolved('hello_logic');
    final dist = freshTmpDir('$label/dist');
    final result = await buildNpmPackage(
      BuildOptions(
        packagePath: fixturePath('hello_logic'),
        outputPath: dist.path,
        engine: engine,
        npmPackageName: 'hello-logic',
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

  /// Sets up the consumer project, npm-installs the built package, runs tsc
  /// and executes the compiled consumer under Node.
  void npmTscNode(String label, BuildResult built, {required bool esm}) {
    final consumer = freshTmpDir('$label/consumer');
    File(p.join(consumer.path, 'package.json')).writeAsStringSync('''
{
  "name": "consumer",
  "private": true,
  ${esm ? '"type": "module",' : ''}
  "dependencies": { "hello-logic": "file:${built.outputDir}" }
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
    File(p.join(consumer.path, 'consumer.ts')).writeAsStringSync(_consumerTs);

    _runChecked('npm', ['install', '--no-audit', '--no-fund'], consumer.path);
    _runChecked('tsc', ['-p', '.'], consumer.path);
    final run = _runChecked('node', ['consumer.js'], consumer.path);
    expect(run.stdout, contains('ALL_ASSERTIONS_PASSED'));

    // Bad usage must be rejected by the generated declarations.
    File(
      p.join(consumer.path, 'consumer.ts'),
    ).writeAsStringSync(_badConsumerTs);
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

  group('dart2js engine (commonjs)', () {
    test(
      'build -> npm install -> tsc -> node',
      () async {
        final built = await build('js-cjs', 'dart2js');
        expect(built.engineId, 'dart2js');
        expect(built.api.exportedNames, [
          'add',
          'greet',
          'half',
          'isEven',
          'createCounter',
        ]);
        npmTscNode('js-cjs', built, esm: false);
      },
      skip: hasNode && hasNpm && hasTsc ? false : 'needs node, npm and tsc',
    );
  });

  group('dart2js engine (esm)', () {
    test('build -> node named imports', () async {
      ensureFixtureResolved('hello_logic');
      final dist = freshTmpDir('js-esm/dist');
      await buildNpmPackage(
        BuildOptions(
          packagePath: fixturePath('hello_logic'),
          outputPath: dist.path,
          engine: 'dart2js',
          moduleFormat: ModuleFormat.esm,
          npmPackageName: 'hello-logic',
        ),
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

  group('wasm engine (esm)', () {
    test(
      'build -> npm install -> tsc -> node',
      () async {
        final built = await build('wasm', 'wasm');
        expect(built.engineId, 'wasm');
        npmTscNode('wasm', built, esm: true);
      },
      skip: hasNode && hasNpm && hasTsc ? false : 'needs node, npm and tsc',
    );
  });
}

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
