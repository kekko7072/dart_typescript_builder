/// The build pipeline: analyze -> generate facade -> compile -> generate
/// `.d.ts` -> package. This is the library API; the CLI in `bin/` is a thin
/// wrapper over [buildNpmPackage].
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'api_analyzer.dart';
import 'backend/compiler_backend.dart';
import 'diagnostics.dart';
import 'facade_generator.dart';
import 'model.dart';
import 'packager.dart';

final class BuildOptions {
  const BuildOptions({
    required this.packagePath,
    required this.outputPath,
    this.engine = 'dart2js',
    this.moduleFormat,
    this.npmPackageName,
    this.dateTimeMode = DateTimeMode.jsDate,
    this.runNpmInstall = true,
    this.verbose = false,
  });

  /// Path to the target Dart package (directory containing pubspec.yaml).
  final String packagePath;

  /// Directory the npm package is written to.
  final String outputPath;

  /// `dart2js` (default) or `wasm`.
  final String engine;

  /// Defaults to [ModuleFormat.commonjs] for dart2js and [ModuleFormat.esm]
  /// for wasm.
  final ModuleFormat? moduleFormat;

  /// npm package name; defaults to the Dart package name with `_` -> `-`.
  final String? npmPackageName;

  /// How `DateTime` crosses the boundary: JS `Date` (default) or Firestore
  /// `Timestamp` from firebase-admin (for TypeScript backends on Firebase).
  final DateTimeMode dateTimeMode;

  /// Run `npm install` in the output directory after packaging, so the
  /// folder is a complete, immediately consumable npm project: the first run
  /// initializes `package-lock.json`, and peer dependencies declared by the
  /// build (firebase-admin in firestore mode) are installed too (npm >= 7
  /// auto-installs peers — requires network when peers are present).
  final bool runNpmInstall;

  final bool verbose;
}

final class BuildResult {
  const BuildResult({
    required this.outputDir,
    required this.npmName,
    required this.files,
    required this.api,
    required this.engineId,
    this.npmInstalled = false,
  });

  final String outputDir;
  final String npmName;

  /// Generated file names, relative to [outputDir].
  final List<String> files;

  final ApiModel api;
  final String engineId;

  /// Whether `npm install` ran in the output directory.
  final bool npmInstalled;
}

/// Runs the full pipeline and returns what was produced.
///
/// Throws [UnsupportedApiException] for public API constructs outside the
/// supported subset and [BuildException] for structural failures.
Future<BuildResult> buildNpmPackage(BuildOptions options) async {
  final backend = CompilerBackend.forEngine(options.engine);
  final moduleFormat =
      options.moduleFormat ??
      (backend.id == 'wasm' ? ModuleFormat.esm : ModuleFormat.commonjs);

  // -- Stage 0: locate the target and make sure it is resolved. -------------
  final target = readTargetPackage(options.packagePath);
  _ensureResolved(target, verbose: options.verbose);

  final npmName = options.npmPackageName ?? target.name.replaceAll('_', '-');
  _validateNpmName(npmName);
  final globalExportKey =
      '__dtb_exports_${npmName.replaceAll(RegExp('[^A-Za-z0-9_]'), '_')}__';

  // -- Stage 1: analyze. -----------------------------------------------------
  final api = await analyzePackage(target, dateTimeMode: options.dateTimeMode);
  if (api.exportedNames.isEmpty) {
    throw BuildException(
      "the public API of '${target.name}' (lib/${target.name}.dart) exports "
      'nothing the tool can bind. Nothing to build.',
    );
  }

  // -- Stage 2: generate the interop facade inside the target package. ------
  final workDir = Directory(
    p.join(target.rootPath, '.dart_tool', 'dart_typescript_builder'),
  )..createSync(recursive: true);
  final facadePath = p.join(workDir.path, 'facade.dart');
  File(facadePath).writeAsStringSync(
    generateFacade(
      api,
      globalExportKey: globalExportKey,
      dateTimeMode: options.dateTimeMode,
    ),
  );

  // -- Stages 3 + 4 + 5: compile, declarations, npm package. ----------------
  final outputDir = Directory(p.canonicalize(options.outputPath))
    ..createSync(recursive: true);
  final backendOutput = await backend.build(
    BackendBuildRequest(
      facadePath: facadePath,
      targetPackageRoot: target.rootPath,
      outputDir: outputDir.path,
      artifactBaseName: target.name,
      moduleFormat: moduleFormat,
      api: api,
      globalExportKey: globalExportKey,
      verbose: options.verbose,
    ),
  );
  final packaged = writeNpmPackage(
    outputDir: outputDir.path,
    npmName: npmName,
    target: target,
    api: api,
    backendOutput: backendOutput,
    engineId: backend.id,
  );
  ensureAnalyzerExclusion(target, outputDir.path);
  final npmInstalled =
      options.runNpmInstall &&
      _npmInstall(outputDir.path, verbose: options.verbose);

  return BuildResult(
    outputDir: packaged.outputDir,
    npmName: npmName,
    files: packaged.files,
    api: api,
    engineId: backend.id,
    npmInstalled: npmInstalled,
  );
}

/// Completes the output as an npm project: `npm install` creates
/// `package-lock.json` (first run = init) and `node_modules`, including
/// declared peer dependencies such as firebase-admin (auto-installed by
/// npm >= 7).
bool _npmInstall(String outputDir, {required bool verbose}) {
  final ProcessResult probe;
  try {
    probe = Process.runSync('npm', ['--version'], runInShell: true);
  } on ProcessException {
    stderr.writeln(
      'warning: npm not found — skipped `npm install` in $outputDir.',
    );
    return false;
  }
  if (probe.exitCode != 0) {
    stderr.writeln(
      'warning: npm not usable — skipped `npm install` in $outputDir.',
    );
    return false;
  }
  if (verbose) {
    stderr.writeln('[npm] install in $outputDir');
  }
  final result = Process.runSync(
    'npm',
    ['install', '--no-audit', '--no-fund'],
    workingDirectory: outputDir,
    runInShell: true,
  );
  if (result.exitCode != 0) {
    throw BuildException(
      'npm install failed in $outputDir '
      '(exit ${result.exitCode}):\n${result.stdout}\n${result.stderr}',
    );
  }
  return true;
}

void _ensureResolved(TargetPackageInfo target, {required bool verbose}) {
  final config = File(
    p.join(target.rootPath, '.dart_tool', 'package_config.json'),
  );
  if (config.existsSync()) return;
  if (verbose) {
    stderr.writeln('[pub] resolving ${target.name} (dart pub get)');
  }
  final result = Process.runSync(Platform.resolvedExecutable, [
    'pub',
    'get',
  ], workingDirectory: target.rootPath);
  if (result.exitCode != 0) {
    throw BuildException(
      'dart pub get failed in ${target.rootPath} '
      '(exit ${result.exitCode}):\n${result.stderr}',
    );
  }
}

/// When the npm package is generated INSIDE the target package (e.g.
/// `<target>/typescript/`), keep that directory out of the target's own
/// `dart analyze`: it holds no Dart code (and may grow a node_modules).
///
/// Creates `analysis_options.yaml` (including `package:lints/recommended.yaml`
/// when the target dev-depends on `lints`) or minimally edits the existing
/// one; every edit is re-parsed and verified before being written, falling
/// back to a warning if the file's shape is unusual.
void ensureAnalyzerExclusion(TargetPackageInfo target, String outputDir) {
  final relative = p.relative(outputDir, from: target.rootPath);
  if (relative.startsWith('..') || p.isAbsolute(relative)) return;
  final topDir = p.split(relative).first;
  final pattern = '$topDir/**';
  final file = File(p.join(target.rootPath, 'analysis_options.yaml'));

  if (!file.existsSync()) {
    final pubspec = File(
      p.join(target.rootPath, 'pubspec.yaml'),
    ).readAsStringSync();
    final hasLints = RegExp(
      r'^\s+lints\s*:',
      multiLine: true,
    ).hasMatch(pubspec);
    file.writeAsStringSync(
      [
        if (hasLints) ...['include: package:lints/recommended.yaml', ''],
        '# The `$topDir/` subdirectory is the generated npm package (the',
        '# TypeScript counterpart of this Dart core); it holds no Dart code,',
        '# so keep it out of dart analyze. (Added by dart_typescript_builder.)',
        'analyzer:',
        '  exclude:',
        '    - $pattern',
        '',
      ].join('\n'),
    );
    return;
  }

  final source = file.readAsStringSync();
  if (_analyzerExcludes(source, pattern)) return;

  final Object? parsed;
  try {
    parsed = loadYaml(source);
  } catch (_) {
    _warnAnalyzerExclusion(file, pattern);
    return;
  }

  final String updated;
  final analyzerSection = parsed is YamlMap ? parsed['analyzer'] : null;
  if (parsed is! YamlMap || analyzerSection == null) {
    updated =
        '${source.trimRight()}\n\n'
        '# The `$topDir/` subdirectory is the generated npm package; it '
        'holds no\n'
        '# Dart code. (Added by dart_typescript_builder.)\n'
        'analyzer:\n'
        '  exclude:\n'
        '    - $pattern\n';
  } else if (analyzerSection is YamlMap && analyzerSection['exclude'] != null) {
    // Append one entry right below the existing `exclude:` line.
    updated = source.replaceFirstMapped(
      RegExp(r'^([ \t]*)exclude[ \t]*:[ \t]*$', multiLine: true),
      (m) => '${m[0]}\n${m[1]}  - $pattern',
    );
  } else {
    // `analyzer:` exists without an exclude list.
    updated = source.replaceFirst(
      RegExp(r'^analyzer[ \t]*:[ \t]*$', multiLine: true),
      'analyzer:\n  exclude:\n    - $pattern',
    );
  }

  if (_analyzerExcludes(updated, pattern)) {
    file.writeAsStringSync(updated);
  } else {
    _warnAnalyzerExclusion(file, pattern);
  }
}

bool _analyzerExcludes(String source, String pattern) {
  try {
    final parsed = loadYaml(source);
    if (parsed is! YamlMap) return false;
    final analyzer = parsed['analyzer'];
    if (analyzer is! YamlMap) return false;
    final exclude = analyzer['exclude'];
    return exclude is YamlList && exclude.contains(pattern);
  } catch (_) {
    return false;
  }
}

void _warnAnalyzerExclusion(File file, String pattern) {
  stderr.writeln(
    'warning: could not update ${file.path} automatically — add '
    "'$pattern' to analyzer.exclude yourself so the generated npm package "
    'stays out of dart analyze.',
  );
}

void _validateNpmName(String name) {
  final valid = RegExp(
    r'^(@[a-z0-9-~][a-z0-9-._~]*\/)?[a-z0-9-~][a-z0-9-._~]*$',
  );
  if (!valid.hasMatch(name)) {
    throw BuildException("'$name' is not a valid npm package name");
  }
}
