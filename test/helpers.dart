import 'dart:io';

import 'package:path/path.dart' as p;

/// Absolute path of a fixture package.
String fixturePath(String name) =>
    p.canonicalize(p.join('test', 'fixtures', name));

/// Fixtures need a package_config before the analyzer can resolve them.
/// They have no dependencies, so this is offline and fast.
void ensureFixtureResolved(String name) {
  final root = fixturePath(name);
  if (File(p.join(root, '.dart_tool', 'package_config.json')).existsSync()) {
    return;
  }
  final result = Process.runSync(Platform.resolvedExecutable, [
    'pub',
    'get',
    '--offline',
  ], workingDirectory: root);
  if (result.exitCode != 0) {
    throw StateError(
      'dart pub get failed for fixture $name:\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
}

/// Scratch directory for integration builds, wiped per run.
Directory freshTmpDir(String label) {
  final dir = Directory(p.canonicalize(p.join('test', '.tmp', label)));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  return dir;
}
