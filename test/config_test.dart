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
}
