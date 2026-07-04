import 'dart:io';

import 'package:dart_typescript_builder/dart_typescript_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  Directory writeConfig(String label, String content) {
    final dir = freshTmpDir('config/$label');
    File(p.join(dir.path, configFileName)).writeAsStringSync(content);
    return dir;
  }

  group('readConfigArgs', () {
    test('returns null when the file does not exist', () {
      final dir = freshTmpDir('config/absent');
      expect(readConfigArgs(dir.path), isNull);
    });

    test('splits a string `args:` into words', () {
      final dir = writeConfig('string', '''
# npm settings and firebase usage for this package.
args: build . --out typescript --datetime firestore --firestore-types
''');
      expect(readConfigArgs(dir.path), [
        'build',
        '.',
        '--out',
        'typescript',
        '--datetime',
        'firestore',
        '--firestore-types',
      ]);
    });

    test('accepts a YAML list `args:`', () {
      final dir = writeConfig('list', '''
args: [build, ., --out, typescript]
''');
      expect(readConfigArgs(dir.path), ['build', '.', '--out', 'typescript']);
    });

    test('old inputs:/output: format fails with a migration message', () {
      final dir = writeConfig('legacy', '''
inputs:
  - lib/models.dart
output: typescript/src
''');
      expect(
        () => readConfigArgs(dir.path),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            allOf(contains('old'), contains('args:')),
          ),
        ),
      );
    });

    test('missing or empty args: fails loudly', () {
      for (final (label, content) in [
        ('no-args', '# only comments\n'),
        ('empty-args', 'args:\n'),
        ('blank-args', 'args: "  "\n'),
        ('wrong-type', 'args: {build: true}\n'),
      ]) {
        final dir = writeConfig(label, content);
        expect(
          () => readConfigArgs(dir.path),
          throwsA(isA<BuildException>()),
          reason: label,
        );
      }
    });

    test('invalid YAML fails with a readable message', () {
      final dir = writeConfig('invalid', 'args: [unclosed\n');
      expect(
        () => readConfigArgs(dir.path),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            contains('not valid YAML'),
          ),
        ),
      );
    });
  });

  group('readConfig clean setting', () {
    test('defaults to enabled when `clean:` is absent', () {
      final dir = writeConfig(
        'clean-default',
        'args: build . --out typescript\n',
      );
      expect(readConfig(dir.path)!.cleanEnabled, isTrue);
    });

    test('`clean: false` disables removal', () {
      final dir = writeConfig(
        'clean-false',
        'args: build . --out typescript\nclean: false\n',
      );
      expect(readConfig(dir.path)!.cleanEnabled, isFalse);
    });

    test('`clean: true` keeps removal enabled', () {
      final dir = writeConfig(
        'clean-true',
        'args: build . --out typescript\nclean: true\n',
      );
      expect(readConfig(dir.path)!.cleanEnabled, isTrue);
    });

    test('a non-boolean `clean:` fails loudly', () {
      final dir = writeConfig(
        'clean-bad',
        'args: build . --out typescript\nclean: maybe\n',
      );
      expect(
        () => readConfig(dir.path),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            contains('clean:'),
          ),
        ),
      );
    });
  });

  group('bare CLI invocation', () {
    final cliScript = p.canonicalize(
      p.join('bin', 'dart_typescript_builder.dart'),
    );

    ProcessResult runBareCli(String cwd) => Process.runSync(
      Platform.resolvedExecutable,
      [cliScript],
      workingDirectory: cwd,
    );

    test('builds using the args pinned in $configFileName', () {
      ensureFixtureResolved('hello_logic');
      final dir = freshTmpDir('config/cli');
      File(p.join(dir.path, configFileName)).writeAsStringSync(
        'args: build ${fixturePath('hello_logic')} '
        '--out ${p.join(dir.path, 'dist')} --no-npm-install\n',
      );
      final result = runBareCli(dir.path);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('Using $configFileName'));
      expect(File(p.join(dir.path, 'dist', 'index.d.ts')).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'dist', '.gitignore')).existsSync(), isTrue);
    });

    test('fails with the migration message on an old-format file', () {
      final dir = freshTmpDir('config/cli-legacy');
      File(
        p.join(dir.path, configFileName),
      ).writeAsStringSync('inputs:\n  - lib/models.dart\noutput: typescript\n');
      final result = runBareCli(dir.path);
      expect(result.exitCode, 64, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stderr, contains('old'));
    });

    test('still prints usage when no config file exists', () {
      final dir = freshTmpDir('config/cli-none');
      final result = runBareCli(dir.path);
      expect(result.exitCode, 64);
      expect(result.stderr, contains('Usage:'));
    });
  });

  group('clean command', () {
    final cliScript = p.canonicalize(
      p.join('bin', 'dart_typescript_builder.dart'),
    );

    ProcessResult runClean(String cwd, [List<String> extra = const []]) =>
        Process.runSync(Platform.resolvedExecutable, [
          cliScript,
          'clean',
          ...extra,
        ], workingDirectory: cwd);

    // Creates a non-empty <dir>/<out> folder, standing in for a generated
    // npm package.
    Directory seedOutput(Directory dir, String out) {
      final outDir = Directory(p.join(dir.path, out))
        ..createSync(recursive: true);
      File(p.join(outDir.path, 'index.d.ts')).writeAsStringSync('// generated');
      return outDir;
    }

    test('removes the output dir pinned in the config', () {
      final dir = freshTmpDir('clean/config-out');
      File(
        p.join(dir.path, configFileName),
      ).writeAsStringSync('args: build . --out typescript\n');
      final outDir = seedOutput(dir, 'typescript');
      final result = runClean(dir.path);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(outDir.existsSync(), isFalse);
      expect(result.stdout, contains('typescript'));
    });

    test('keeps the output dir when `clean: false`', () {
      final dir = freshTmpDir('clean/disabled');
      File(
        p.join(dir.path, configFileName),
      ).writeAsStringSync('args: build . --out typescript\nclean: false\n');
      final outDir = seedOutput(dir, 'typescript');
      final result = runClean(dir.path);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(outDir.existsSync(), isTrue);
      expect(result.stdout, contains('Keeping'));
    });

    test('--out overrides the config-pinned output dir', () {
      final dir = freshTmpDir('clean/out-override');
      File(
        p.join(dir.path, configFileName),
      ).writeAsStringSync('args: build . --out typescript\n');
      final pinned = seedOutput(dir, 'typescript');
      final override = seedOutput(dir, 'build_ts');
      final result = runClean(dir.path, ['--out', 'build_ts']);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(override.existsSync(), isFalse);
      expect(pinned.existsSync(), isTrue);
    });

    test('falls back to the default output dir with no config', () {
      final dir = freshTmpDir('clean/no-config');
      final outDir = seedOutput(dir, defaultOutputDir);
      final result = runClean(dir.path);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(outDir.existsSync(), isFalse);
    });

    test('reports nothing to remove when the dir is absent', () {
      final dir = freshTmpDir('clean/absent');
      final result = runClean(dir.path);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('Nothing to remove'));
    });

    test('rejects more than one path argument', () {
      final dir = freshTmpDir('clean/too-many');
      final result = runClean(dir.path, ['a', 'b']);
      expect(result.exitCode, 64);
      expect(result.stderr, contains('at most one'));
    });
  });
}
