/// When the npm output lands inside the target package, the target's
/// analysis_options.yaml must gain (or already have) the exclusion.
library;

import 'dart:io';

import 'package:dart_typescript_builder/dart_typescript_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Directory root;

  TargetPackageInfo scratchTarget({String? analysisOptions, String? pubspec}) {
    root = freshTmpDir('analysis-options');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(
      pubspec ??
          '''
name: scratch_pkg
version: 0.1.0
environment:
  sdk: ^3.5.0
dev_dependencies:
  lints: ^6.0.0
''',
    );
    Directory(p.join(root.path, 'lib')).createSync();
    File(
      p.join(root.path, 'lib', 'scratch_pkg.dart'),
    ).writeAsStringSync('int one() => 1;\n');
    if (analysisOptions != null) {
      File(
        p.join(root.path, 'analysis_options.yaml'),
      ).writeAsStringSync(analysisOptions);
    }
    return readTargetPackage(root.path);
  }

  String optionsSource() =>
      File(p.join(root.path, 'analysis_options.yaml')).readAsStringSync();

  test('creates analysis_options.yaml with lints include', () {
    final target = scratchTarget();
    ensureAnalyzerExclusion(target, p.join(root.path, 'typescript'));
    final source = optionsSource();
    expect(source, contains('include: package:lints/recommended.yaml'));
    expect(source, contains('- typescript/**'));
  });

  test('creates without lints include when target lacks the dep', () {
    final target = scratchTarget(
      pubspec:
          'name: scratch_pkg\nversion: 0.1.0\n'
          'environment:\n  sdk: ^3.5.0\n',
    );
    ensureAnalyzerExclusion(target, p.join(root.path, 'typescript'));
    final source = optionsSource();
    expect(source, isNot(contains('include:')));
    expect(source, contains('- typescript/**'));
  });

  test('appends to an existing exclude list, preserving content', () {
    final target = scratchTarget(
      analysisOptions: '''
include: package:lints/recommended.yaml

analyzer:
  exclude:
    - build/**
''',
    );
    ensureAnalyzerExclusion(target, p.join(root.path, 'typescript'));
    final source = optionsSource();
    expect(source, contains('- build/**'));
    expect(source, contains('- typescript/**'));
    expect(source, contains('include: package:lints/recommended.yaml'));
  });

  test('adds exclude to an existing analyzer section', () {
    final target = scratchTarget(
      analysisOptions: '''
analyzer:
  language:
    strict-casts: true
''',
    );
    ensureAnalyzerExclusion(target, p.join(root.path, 'typescript'));
    final source = optionsSource();
    expect(source, contains('- typescript/**'));
    expect(source, contains('strict-casts: true'));
  });

  test('no-op when the exclusion already exists', () {
    const existing = '''
analyzer:
  exclude:
    - typescript/**
''';
    final target = scratchTarget(analysisOptions: existing);
    ensureAnalyzerExclusion(target, p.join(root.path, 'typescript'));
    expect(optionsSource(), existing);
  });

  test('no-op when the output is outside the package', () {
    final target = scratchTarget();
    ensureAnalyzerExclusion(target, freshTmpDir('elsewhere').path);
    expect(
      File(p.join(root.path, 'analysis_options.yaml')).existsSync(),
      isFalse,
    );
  });
}
