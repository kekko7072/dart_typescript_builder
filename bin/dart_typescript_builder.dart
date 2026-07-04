import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_typescript_builder/dart_typescript_builder.dart';
import 'package:path/path.dart' as p;

const _usageExitCode = 64;
const _buildFailureExitCode = 1;

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addCommand('build', _buildParser())
    ..addCommand('clean', _cleanParser());

  // A bare invocation (the shape a post-`pub get` hook runs) builds with the
  // arguments pinned in dart_typescript_builder.yaml next to pubspec.yaml.
  var effectiveArguments = arguments;
  if (arguments.isEmpty) {
    final List<String>? configArgs;
    try {
      configArgs = readConfigArgs(Directory.current.path);
    } on BuildException catch (e) {
      stderr.writeln(e);
      exit(_usageExitCode);
    }
    if (configArgs != null) {
      stdout.writeln('Using $configFileName: ${configArgs.join(' ')}');
      effectiveArguments = configArgs;
    }
  }

  final ArgResults results;
  try {
    results = parser.parse(effectiveArguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _printUsage(parser, to: stderr);
    exit(_usageExitCode);
  }

  final command = results.command;
  final help = results['help'] as bool;
  if (help || command == null) {
    _printUsage(parser, to: help ? stdout : stderr);
    exit(help ? 0 : _usageExitCode);
  }

  switch (command.name) {
    case 'build':
      await _runBuild(parser, command);
    case 'clean':
      _runClean(parser, command);
    default:
      _printUsage(parser, to: stderr);
      exit(_usageExitCode);
  }
}

ArgParser _buildParser() => ArgParser()
  ..addOption(
    'out',
    abbr: 'o',
    help: 'Output directory for the npm package.',
    defaultsTo: defaultOutputDir,
  )
  ..addOption(
    'engine',
    allowed: ['dart2js', 'js', 'wasm', 'dart2wasm'],
    defaultsTo: 'dart2js',
    help: 'Compiler engine.',
  )
  ..addOption(
    'module',
    allowed: ['commonjs', 'cjs', 'esm', 'module'],
    help:
        'Node module format '
        '(default: commonjs for dart2js, esm for wasm).',
  )
  ..addOption(
    'package-name',
    help: 'npm package name (default: Dart name with _ -> -).',
  )
  ..addOption(
    'datetime',
    allowed: [
      'js-date',
      'date',
      'firestore',
      'firestore-timestamp',
      'timestamp',
    ],
    defaultsTo: 'js-date',
    help:
        'How DateTime crosses the boundary: JS Date, or Firestore '
        'Timestamp from firebase-admin (for Firebase backends).',
  )
  ..addFlag(
    'firestore-types',
    negatable: false,
    help:
        'Marshal the full firebase-admin Firestore value set inside '
        'dynamic data: Buffer/Uint8Array <-> Uint8List (copied), and '
        'identity-preserving pass-through for GeoPoint, '
        'DocumentReference, FieldValue and VectorValue. '
        'Requires --datetime firestore.',
  )
  ..addFlag(
    'npm-install',
    defaultsTo: true,
    help:
        'Run `npm install` in the output directory after packaging '
        '(first run initializes package-lock.json).',
  )
  ..addFlag('verbose', abbr: 'v', negatable: false);

ArgParser _cleanParser() => ArgParser()
  ..addOption(
    'out',
    abbr: 'o',
    help:
        'Output directory to remove (default: the `--out` pinned in '
        '$configFileName, else $defaultOutputDir).',
  )
  ..addFlag('verbose', abbr: 'v', negatable: false);

Future<void> _runBuild(ArgParser parser, ArgResults command) async {
  if (command.rest.length != 1) {
    stderr.writeln('expected exactly one <path-to-dart-package> argument.');
    _printUsage(parser, to: stderr);
    exit(_usageExitCode);
  }

  try {
    final result = await buildNpmPackage(
      BuildOptions(
        packagePath: command.rest.single,
        outputPath: command['out'] as String,
        engine: command['engine'] as String,
        moduleFormat: command['module'] == null
            ? null
            : ModuleFormat.parse(command['module'] as String),
        npmPackageName: command['package-name'] as String?,
        dateTimeMode: DateTimeMode.parse(command['datetime'] as String),
        firestoreTypes: command['firestore-types'] as bool,
        runNpmInstall: command['npm-install'] as bool,
        verbose: command['verbose'] as bool,
      ),
    );
    stdout
      ..writeln(
        'Built npm package `${result.npmName}` '
        '(engine: ${result.engineId}) in ${result.outputDir}',
      )
      ..writeln('Exports: ${result.api.exportedNames.join(', ')}');
    for (final file in result.files) {
      stdout.writeln('  ${result.outputDir}/$file');
    }
    if (result.npmInstalled) {
      stdout.writeln('npm install: done (package-lock.json + node_modules)');
    }
  } on UnsupportedApiException catch (e) {
    stderr.writeln(e.message);
    exit(_buildFailureExitCode);
  } on BuildException catch (e) {
    stderr.writeln(e);
    exit(_buildFailureExitCode);
  }
}

/// Removes the generated npm package directory — the mirror of `build`, wired
/// into a `flutter clean` shell hook so the compiled output does not outlive
/// the Flutter build artifacts it was generated alongside.
void _runClean(ArgParser parser, ArgResults command) {
  // `clean` targets a package directory (default: the current directory), the
  // same place `build`'s <path> points at.
  final String packagePath;
  switch (command.rest.length) {
    case 0:
      packagePath = '.';
    case 1:
      packagePath = command.rest.single;
    default:
      stderr.writeln(
        'clean takes at most one <path-to-dart-package> argument.',
      );
      _printUsage(parser, to: stderr);
      exit(_usageExitCode);
  }

  final DtbConfig? config;
  try {
    config = readConfig(packagePath);
  } on BuildException catch (e) {
    stderr.writeln(e);
    exit(_buildFailureExitCode);
  }

  if (config != null && !config.cleanEnabled) {
    stdout.writeln(
      'Keeping the generated npm package ($configFileName has `clean: false`).',
    );
    return;
  }

  // Which folder to remove: an explicit --out wins, then the `--out` pinned in
  // the config, then the build default — so `clean` removes exactly what
  // `build` would have created.
  var outputDir = command['out'] as String?;
  outputDir ??= config == null ? null : _outFromConfigArgs(parser, config.args);
  outputDir ??= defaultOutputDir;

  final target = Directory(p.join(packagePath, outputDir));
  if (target.existsSync()) {
    target.deleteSync(recursive: true);
    stdout.writeln('Removed the generated npm package: $outputDir');
  } else {
    stdout.writeln('Nothing to remove: $outputDir is already absent.');
  }
}

/// Extracts the `--out` value from the config's pinned `args:` by re-parsing
/// them with the real parser, so `clean` and `build` agree on the folder.
/// Returns null when the pinned args are not a `build` invocation or are
/// malformed (`build` surfaces those; `clean` falls back to the default).
String? _outFromConfigArgs(ArgParser parser, List<String> configArgs) {
  try {
    final build = parser.parse(configArgs).command;
    if (build?.name == 'build') return build!['out'] as String;
  } on FormatException {
    // Fall through to the default; a broken build config fails loudly on build.
  }
  return null;
}

void _printUsage(ArgParser parser, {required IOSink to}) {
  to
    ..writeln('Compile a Dart package into a typed npm package.')
    ..writeln()
    ..writeln('Usage:')
    ..writeln(
      '  dart_typescript_builder build <path-to-dart-package> '
      '[--out <dir>] [--engine dart2js|wasm]',
    )
    ..writeln(
      '      [--module commonjs|esm] [--package-name <npm-name>] '
      '[--verbose]',
    )
    ..writeln(
      '  dart_typescript_builder clean [<path-to-dart-package>] [--out <dir>]',
    )
    ..writeln()
    ..writeln(
      'With no arguments, the build command is read from the `args:` entry '
      'of $configFileName\nin the current directory (if present).',
    )
    ..writeln()
    ..writeln('build:')
    ..writeln(parser.commands['build']!.usage)
    ..writeln()
    ..writeln('clean:')
    ..writeln(parser.commands['clean']!.usage);
}
