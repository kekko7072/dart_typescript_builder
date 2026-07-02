import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_typescript_builder/dart_typescript_builder.dart';

const _usageExitCode = 64;
const _buildFailureExitCode = 1;

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addCommand(
      'build',
      ArgParser()
        ..addOption(
          'out',
          abbr: 'o',
          help: 'Output directory for the npm package.',
          defaultsTo: 'dist',
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
        ..addFlag('verbose', abbr: 'v', negatable: false),
    );

  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _printUsage(parser, to: stderr);
    exit(_usageExitCode);
  }

  final command = results.command;
  if (results['help'] as bool || command == null || command.name != 'build') {
    _printUsage(parser, to: results['help'] as bool ? stdout : stderr);
    exit(results['help'] as bool ? 0 : _usageExitCode);
  }

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
  } on UnsupportedApiException catch (e) {
    stderr.writeln(e.message);
    exit(_buildFailureExitCode);
  } on BuildException catch (e) {
    stderr.writeln(e);
    exit(_buildFailureExitCode);
  }
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
    ..writeln()
    ..writeln(parser.commands['build']!.usage);
}
