import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'diagnostics.dart';

/// Per-package configuration file: pins the CLI arguments next to
/// `pubspec.yaml` so a bare `dart run dart_typescript_builder` (e.g. from a
/// post-`pub get` shell hook) rebuilds the npm package without repeating the
/// flags.
const configFileName = 'dart_typescript_builder.yaml';

/// Output directory used by `build` (and targeted by `clean`) when `--out` is
/// not pinned in [configFileName]. Mirrors the `build` command's `--out`
/// default in `bin/`.
const defaultOutputDir = 'dist';

/// A parsed, validated view of [configFileName].
class DtbConfig {
  const DtbConfig({required this.args, required this.cleanEnabled});

  /// The pinned CLI arguments (the `args:` entry) split into words.
  final List<String> args;

  /// Whether `clean` removes the generated output directory. Defaults to true;
  /// set `clean: false` in the config to keep the npm package on
  /// `flutter clean`.
  final bool cleanEnabled;
}

/// Reads and validates [configFileName] inside [directory].
///
/// Returns null when the file does not exist — the caller falls back to normal
/// argument handling. Throws [BuildException] with an actionable message when
/// the file exists but holds no usable `args:` entry (or an invalid `clean:`
/// value), so a misconfigured automation fails loudly instead of printing
/// usage.
DtbConfig? readConfig(String directory) {
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

  return DtbConfig(args: words, cleanEnabled: _readCleanEnabled(document));
}

/// Reads the CLI arguments pinned in [configFileName] inside [directory].
///
/// Convenience wrapper over [readConfig] for callers that only need the build
/// arguments; see [readConfig] for the null/throw contract.
List<String>? readConfigArgs(String directory) => readConfig(directory)?.args;

/// Interprets the optional `clean:` key. Absent (or an empty value) means the
/// default — `true`, so `clean` removes the generated output directory; an
/// explicit `false` keeps it. Any other value fails loudly.
bool _readCleanEnabled(YamlMap document) {
  final value = document['clean'];
  if (value == null) return true;
  if (value is bool) return value;
  throw BuildException(
    '$configFileName: `clean:` must be true or false, got `$value`.',
  );
}
