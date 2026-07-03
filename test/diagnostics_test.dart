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

  test('callback with named parameters -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_callback_named'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('callbacks support required positional parameters only'),
            matches(r'unsupported_callback_named\.dart:2'),
          ),
        ),
      ),
    );
  });

  test('generic class -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_generic'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith("Unsupported: generic class 'Box' at "),
            matches(r'unsupported_generic\.dart:2'),
          ),
        ),
      ),
    );
  });

  test('extending an unexported class -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_extends_private'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains("class 'Child' extends '_Base'"),
            contains('not exported'),
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

  test('method named `then` -> Unsupported (thenable hijack)', () async {
    await expectLater(
      analyzeFixture('unsupported_then'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith("Unsupported: member 'Job.then'"),
            matches(r'unsupported_then\.dart:'),
          ),
        ),
      ),
    );
  });

  test('nullable map key -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_nullable_map_key'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          contains("map key type 'String?'"),
        ),
      ),
    );
  });

  test('getter/setter type mismatch -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_accessor_mismatch'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          contains("getter/setter type mismatch for 'Box.value'"),
        ),
      ),
    );
  });

  test('static setter -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_static_setter'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          contains("static setter 'Config.mode'"),
        ),
      ),
    );
  });

  test('strict-mode reserved word as function name -> Unsupported', () async {
    await expectLater(
      analyzeFixture('unsupported_strict_reserved'),
      throwsA(
        isA<UnsupportedApiException>().having(
          (e) => e.message,
          'message',
          contains("function 'let' — the name is a reserved word"),
        ),
      ),
    );
  });

  test('class named Date alongside DateTime usage -> rejection', () async {
    await expectLater(
      analyzeFixture('unsupported_date_class'),
      throwsA(
        isA<BuildException>().having(
          (e) => e.message,
          'message',
          contains("class is named 'Date'"),
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
