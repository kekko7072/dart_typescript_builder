/// Compile a Dart package into a typed npm package.
///
/// Write your logic once in Dart, use it from Flutter *and* from a
/// TypeScript/Node backend: this library analyzes the target package's public
/// API, generates a `dart:js_interop` facade, compiles it (dart2js or
/// dart2wasm), and emits an installable npm package with TypeScript
/// declarations.
///
/// This is a bindings generator + packaging tool (think `wasm-pack` for
/// Dart), NOT a source-to-source transpiler: the Dart stays Dart and the
/// compiler does the heavy lifting.
library;

export 'src/api_analyzer.dart'
    show TargetPackageInfo, analyzePackage, readTargetPackage;
export 'src/backend/compiler_backend.dart';
export 'src/backend/dart2js_backend.dart';
export 'src/backend/dart2wasm_backend.dart';
export 'src/diagnostics.dart';
export 'src/dts_generator.dart';
export 'src/facade_generator.dart';
export 'src/model.dart';
export 'src/packager.dart' show PackageResult, writeNpmPackage;
export 'src/pipeline.dart';
