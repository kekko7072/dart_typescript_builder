/// Unsupported input must throw `Unsupported: <construct> at <file>:<line>`
/// (or a BuildException for whole-package rejections) — never emit silently
/// broken output.
library;

import 'package:dart_typescript_builder/dart_typescript_builder.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  Future<ApiModel> analyzeFixture(String name) {
    ensureFixtureResolved(name);
    return analyzePackage(readTargetPackage(fixturePath(name)));
  }

  test('List parameter -> Unsupported with file:line and Phase 2 hint',
      () async {
    await expectLater(
      analyzeFixture('unsupported_list'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith("Unsupported: type 'List<int>' in parameter 'values' "
                "of function 'sum' at "),
            matches(r'unsupported_list\.dart:2'),
            contains('Phase 2'),
          ),
        ),
      ),
    );
  });

  test('named parameter -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_named'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith("Unsupported: named parameter 'width' of function "
                "'pad' at "),
            matches(r'unsupported_named\.dart:2'),
          ),
        ),
      ),
    );
  });

  test('enum -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_enum'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith("Unsupported: enum 'Color' at "),
            matches(r'unsupported_enum\.dart:2'),
            contains('Phase 3'),
          ),
        ),
      ),
    );
  });

  test('dart:ffi import -> whole-package rejection', () async {
    await expectLater(
      analyzeFixture('ffi_logic'),
      throwsA(
        isA<BuildException>().having(
          (e) => e.message,
          'message',
          contains('imports dart:ffi'),
        ),
      ),
    );
  });

  test('unknown engine -> BuildException', () {
    expect(
      () => CompilerBackend.forEngine('rollup'),
      throwsA(isA<BuildException>()),
    );
  });

  test('wasm engine rejects commonjs module format', () async {
    ensureFixtureResolved('hello_logic');
    await expectLater(
      buildNpmPackage(
        BuildOptions(
          packagePath: fixturePath('hello_logic'),
          outputPath: freshTmpDir('wasm-cjs-reject').path,
          engine: 'wasm',
          moduleFormat: ModuleFormat.commonjs,
        ),
      ),
      throwsA(
        isA<BuildException>().having(
          (e) => e.message,
          'message',
          contains('requires --module esm'),
        ),
      ),
    );
  });
}
