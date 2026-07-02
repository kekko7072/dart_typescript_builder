/// Stage 3 of the pipeline: the compiler backend seam.
///
/// The analyze / facade-generation / `.d.ts` / packaging stages are
/// engine-agnostic; only "compile the facade and wire its output into a Node
/// module" differs per engine. New engines implement [CompilerBackend] and
/// register in [CompilerBackend.forEngine] — nothing else changes.
library;

import '../diagnostics.dart';
import '../model.dart';
import 'dart2js_backend.dart';
import 'dart2wasm_backend.dart';

/// Node module format of the generated npm package.
enum ModuleFormat {
  commonjs('commonjs'),
  esm('esm');

  const ModuleFormat(this.id);

  final String id;

  static ModuleFormat parse(String value) => switch (value) {
    'commonjs' || 'cjs' => ModuleFormat.commonjs,
    'esm' || 'module' => ModuleFormat.esm,
    _ => throw BuildException(
      "unknown module format '$value' (expected 'commonjs' or 'esm')",
    ),
  };
}

/// Everything a backend needs to compile the facade and emit its part of the
/// npm package.
final class BackendBuildRequest {
  const BackendBuildRequest({
    required this.facadePath,
    required this.targetPackageRoot,
    required this.outputDir,
    required this.artifactBaseName,
    required this.moduleFormat,
    required this.api,
    required this.globalExportKey,
    required this.verbose,
  });

  /// Absolute path of the generated facade entrypoint. Lives inside the
  /// target package so the compiler resolves `package:` imports from the
  /// target's own package_config.
  final String facadePath;

  final String targetPackageRoot;

  /// Absolute path of the npm package directory being assembled.
  final String outputDir;

  /// Base name for compiled artifacts (e.g. `my_logic` -> `my_logic.dart.js`).
  final String artifactBaseName;

  final ModuleFormat moduleFormat;
  final ApiModel api;

  /// `globalThis` property the facade installs its exports under.
  final String globalExportKey;

  final bool verbose;
}

/// What a backend produced: the runtime files it wrote into the output
/// directory, plus the `package.json` fields it requires.
final class BackendOutput {
  const BackendOutput({
    required this.emittedFiles,
    required this.packageJsonFields,
  });

  /// File names (relative to the output dir) the backend wrote, entry module
  /// (`index.js`) first.
  final List<String> emittedFiles;

  /// Backend-specific `package.json` fields (`type`, `engines`, ...).
  final Map<String, Object?> packageJsonFields;
}

/// A compiler engine: compiles the generated facade and emits the Node
/// module glue for its output format.
abstract interface class CompilerBackend {
  /// Engine id as accepted by `--engine`.
  String get id;

  Future<BackendOutput> build(BackendBuildRequest request);

  /// Resolves an `--engine` flag value to a backend.
  static CompilerBackend forEngine(String engine) => switch (engine) {
    'dart2js' || 'js' => Dart2JsBackend(),
    'wasm' || 'dart2wasm' => Dart2WasmBackend(),
    _ => throw BuildException(
      "unknown engine '$engine' (expected 'dart2js' or 'wasm')",
    ),
  };
}
