/// Diagnostics for `dart_typescript_builder`.
///
/// The contract (see the build spec): unsupported constructs must *fail
/// loudly* with `Unsupported: <construct> at <file>:<line>` so the user gets a
/// precise worklist instead of silently broken output.
library;

/// Thrown when the target package's public API uses a construct the current
/// phase of the tool cannot marshal across the Dart/TypeScript boundary.
final class UnsupportedApiException implements Exception {
  UnsupportedApiException(this.construct, {this.file, this.line, this.hint});

  /// Human-readable description of the offending construct, e.g.
  /// `named parameter 'radix' of function 'parse'`.
  final String construct;

  /// Absolute path of the file declaring the construct, when known.
  final String? file;

  /// 1-based line number of the declaration, when known.
  final int? line;

  /// Optional guidance (e.g. which roadmap phase will add support).
  final String? hint;

  String get message {
    final location = file == null ? '<unknown location>' : '$file:${line ?? 0}';
    final suffix = hint == null ? '' : '\n  hint: $hint';
    return 'Unsupported: $construct at $location$suffix';
  }

  @override
  String toString() => message;
}

/// Thrown for build failures that are not per-declaration API issues:
/// bad input paths, packages that cannot target JS at all (`dart:ffi`,
/// `dart:mirrors`), compiler invocation failures, output collisions.
final class BuildException implements Exception {
  BuildException(this.message);

  final String message;

  @override
  String toString() => 'dart_typescript_builder: $message';
}
