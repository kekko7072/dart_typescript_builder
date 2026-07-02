/// The build pipeline: analyze -> generate facade -> compile -> generate
/// `.d.ts` -> package. This is the library API; the CLI in `bin/` is a thin
/// wrapper over [buildNpmPackage].
library;

import 'dart:io';

import 'package:path/path.dart' as p;

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

  final bool verbose;
}

final class BuildResult {
  const BuildResult({
    required this.outputDir,
    required this.npmName,
    required this.files,
    required this.api,
    required this.engineId,
  });

  final String outputDir;
  final String npmName;

  /// Generated file names, relative to [outputDir].
  final List<String> files;

  final ApiModel api;
  final String engineId;
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

  final npmName =
      options.npmPackageName ?? target.name.replaceAll('_', '-');
  _validateNpmName(npmName);
  final globalExportKey =
      '__dtb_exports_${npmName.replaceAll(RegExp('[^A-Za-z0-9_]'), '_')}__';

  // -- Stage 1: analyze. -----------------------------------------------------
  final api = await analyzePackage(target);
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
    generateFacade(api, globalExportKey: globalExportKey),
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

  return BuildResult(
    outputDir: packaged.outputDir,
    npmName: npmName,
    files: packaged.files,
    api: api,
    engineId: backend.id,
  );
}

void _ensureResolved(TargetPackageInfo target, {required bool verbose}) {
  final config = File(
    p.join(target.rootPath, '.dart_tool', 'package_config.json'),
  );
  if (config.existsSync()) return;
  if (verbose) {
    stderr.writeln('[pub] resolving ${target.name} (dart pub get)');
  }
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['pub', 'get'],
    workingDirectory: target.rootPath,
  );
  if (result.exitCode != 0) {
    throw BuildException(
      'dart pub get failed in ${target.rootPath} '
      '(exit ${result.exitCode}):\n${result.stderr}',
    );
  }
}

void _validateNpmName(String name) {
  final valid = RegExp(r'^(@[a-z0-9-~][a-z0-9-._~]*\/)?[a-z0-9-~][a-z0-9-._~]*$');
  if (!valid.hasMatch(name)) {
    throw BuildException("'$name' is not a valid npm package name");
  }
}
