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

  test('function-typed parameter -> Unsupported with file:line', () async {
    await expectLater(
      analyzeFixture('unsupported_callback'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith(
              "Unsupported: function type 'int Function(int)' in parameter "
              "'transform' of function 'apply' at ",
            ),
            matches(r'unsupported_callback\.dart:2'),
            contains('callback marshalling'),
          ),
        ),
      ),
    );
  });

  test('Stream outside an abstract contract -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_stream'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith(
              "Unsupported: type 'Stream<int>' in return type of function "
              "'ticks' at ",
            ),
            matches(r'unsupported_stream\.dart:2'),
            contains('Phase 4'),
          ),
        ),
      ),
    );
  });

  test('non-literal default value -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_default'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith(
              "Unsupported: default value `kWidth` of parameter 'width' of "
              "function 'pad' is not an inlinable literal at ",
            ),
            matches(r'unsupported_default\.dart:4'),
            contains('literal defaults'),
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
