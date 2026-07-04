import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'diagnostics.dart';

/// Per-package configuration file: pins the CLI arguments next to
/// `pubspec.yaml` so a bare `dart run dart_typescript_builder` (e.g. from a
/// post-`pub get` shell hook) rebuilds the npm package without repeating the
/// flags.
const configFileName = 'dart_typescript_builder.yaml';

/// Reads the CLI arguments pinned in [configFileName] inside [directory].
///
/// Returns null when the file does not exist — the caller falls back to
/// normal argument handling. Throws [BuildException] with an actionable
/// message when the file exists but holds no usable `args:` entry, so a
/// misconfigured automation fails loudly instead of printing usage.
List<String>? readConfigArgs(String directory) {
  final file = File(p.join(directory, configFileName));
  if (!file.existsSync()) return null;

  final Object? document;
  try {
    document = loadYaml(file.readAsStringSync(), sourceUrl: file.uri);
  } on YamlException catch (e) {
    throw BuildException('$configFileName is not valid YAML: ${e.message}');
  }

  const expected =
      'expected an `args:` entry holding the build command, e.g.\n'
      '  args: build . --out typescript --datetime firestore';
  if (document is! YamlMap) {
    throw BuildException('$configFileName: $expected');
  }
  final args = document['args'];
  if (args == null) {
    // The pre-0.3 format configured the build with `inputs:`/`output:` keys;
    // recognize it and point at the migration instead of a generic error.
    final legacyKeys = ['inputs', 'output'].where(document.containsKey);
    if (legacyKeys.isNotEmpty) {
      throw BuildException(
        '$configFileName uses the old `${legacyKeys.join('`/`')}` format, '
        'which this version no longer reads — $expected',
      );
    }
    throw BuildException('$configFileName: $expected');
  }

  final words = switch (args) {
    String() => args.trim().split(RegExp(r'\s+')),
    YamlList() => [for (final arg in args) '$arg'],
    _ => throw BuildException(
      '$configFileName: `args:` must be a string or a list of strings.',
    ),
  };
  if (words.isEmpty || words.every((word) => word.isEmpty)) {
    throw BuildException('$configFileName: `args:` is empty — $expected');
  }
  return words;
}
