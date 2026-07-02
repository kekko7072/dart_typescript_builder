/// Stage 1 of the pipeline: read the target package's *resolved* public API
/// with `package:analyzer` and lower it into the boundary [ApiModel].
///
/// Everything outside the currently supported subset throws
/// [UnsupportedApiException] with an exact `file:line` — never emit silently
/// broken output.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart' as types;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'diagnostics.dart';
import 'model.dart';

/// Metadata read from the target package's `pubspec.yaml`.
final class TargetPackageInfo {
  const TargetPackageInfo({
    required this.name,
    required this.version,
    required this.description,
    required this.rootPath,
    required this.entryLibraryPath,
  });

  final String name;
  final String version;
  final String? description;
  final String rootPath;
  final String entryLibraryPath;

  String get entryLibraryUri => 'package:$name/${p.basename(entryLibraryPath)}';
}

/// Names that would collide with `Object`/JS object plumbing when exported
/// through the generated wrapper class.
const _reservedMemberNames = {
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
  'constructor',
  '__proto__',
};

/// TypeScript reserved words that cannot be used as `export function` names.
const _tsReservedWords = {
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'default',
  'delete',
  'do',
  'else',
  'enum',
  'export',
  'extends',
  'false',
  'finally',
  'for',
  'function',
  'if',
  'import',
  'in',
  'instanceof',
  'new',
  'null',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'typeof',
  'var',
  'void',
  'while',
  'with',
};

/// Reads `pubspec.yaml` and locates the conventional public entrypoint
/// (`lib/<name>.dart`).
TargetPackageInfo readTargetPackage(String packagePath) {
  final root = p.canonicalize(packagePath);
  final pubspecFile = File(p.join(root, 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) {
    throw BuildException(
      "'$packagePath' is not a Dart package: no pubspec.yaml found at "
      '${pubspecFile.path}',
    );
  }
  final pubspec = loadYaml(pubspecFile.readAsStringSync());
  if (pubspec is! YamlMap || pubspec['name'] is! String) {
    throw BuildException('${pubspecFile.path} has no valid `name:` field');
  }
  final name = pubspec['name'] as String;
  final entry = p.join(root, 'lib', '$name.dart');
  if (!File(entry).existsSync()) {
    throw BuildException(
      'expected the public entrypoint library at lib/$name.dart '
      '(package convention). Found nothing at $entry.',
    );
  }
  return TargetPackageInfo(
    name: name,
    version: pubspec['version'] is String
        ? pubspec['version'] as String
        : '0.1.0',
    description: pubspec['description'] is String
        ? pubspec['description'] as String
        : null,
    rootPath: root,
    entryLibraryPath: entry,
  );
}

/// Analyzes [package] and returns its boundary API model.
Future<ApiModel> analyzePackage(TargetPackageInfo package) async {
  final packageConfig = File(
    p.join(package.rootPath, '.dart_tool', 'package_config.json'),
  );
  if (!packageConfig.existsSync()) {
    throw BuildException(
      'the target package has not been resolved — run `dart pub get` in '
      '${package.rootPath} first (the build pipeline normally does this '
      'automatically).',
    );
  }

  final collection = AnalysisContextCollection(
    includedPaths: [package.rootPath],
  );
  final session = collection
      .contextFor(package.entryLibraryPath)
      .currentSession;
  final resolved = await session.getResolvedLibrary(package.entryLibraryPath);
  if (resolved is! ResolvedLibraryResult) {
    throw BuildException(
      'failed to resolve ${package.entryLibraryPath}: $resolved',
    );
  }
  final library = resolved.element;

  _rejectForbiddenPlatformImports(library, package);

  final functions = <FunctionApi>[];
  final classes = <ClassApi>[];

  final names = library.exportNamespace.definedNames2.keys.toList()..sort();
  for (final name in names) {
    if (name.endsWith('=')) continue; // setter entries; handled with getters
    if (name.startsWith('_')) continue;
    final element = library.exportNamespace.definedNames2[name]!;
    switch (element) {
      case TopLevelFunctionElement():
        functions.add(_lowerFunction(element, kind: 'function'));
      case ClassElement():
        classes.add(_lowerClass(element));
      case EnumElement():
        throw UnsupportedApiException(
          "enum '$name'",
          file: _fileOf(element),
          line: _lineOf(element),
          hint: 'enums are planned for Phase 3 (string-literal unions).',
        );
      case MixinElement():
        throw UnsupportedApiException(
          "mixin '$name'",
          file: _fileOf(element),
          line: _lineOf(element),
        );
      case ExtensionElement():
        // Extensions are compile-time sugar with no JS identity; skip them
        // silently — they cannot be called from JS anyway.
        continue;
      case TypeAliasElement():
        throw UnsupportedApiException(
          "typedef '$name'",
          file: _fileOf(element),
          line: _lineOf(element),
        );
      case GetterElement() || SetterElement() || TopLevelVariableElement():
        throw UnsupportedApiException(
          "top-level variable or accessor '$name'",
          file: _fileOf(element),
          line: _lineOf(element),
          hint: 'planned for Phase 2; wrap it in a function for now.',
        );
      default:
        throw UnsupportedApiException(
          "declaration '$name' (${element.kind.displayName})",
          file: _fileOf(element),
          line: _lineOf(element),
        );
    }
  }

  _rejectNameCollisions(functions, classes);

  return ApiModel(
    dartPackageName: package.name,
    libraryUri: package.entryLibraryUri,
    functions: functions,
    classes: classes,
  );
}

/// `dart:ffi` / `dart:mirrors` do not compile to JS or WASM at all: reject the
/// whole package with a clear message. Walks the package-local import/export
/// closure starting at the public entrypoint.
void _rejectForbiddenPlatformImports(
  LibraryElement entry,
  TargetPackageInfo package,
) {
  final seen = <Uri>{};
  final queue = <LibraryElement>[entry];
  while (queue.isNotEmpty) {
    final library = queue.removeLast();
    if (!seen.add(library.uri)) continue;
    for (final fragment in library.fragments) {
      final neighbors = [
        for (final import in fragment.libraryImports) import.importedLibrary,
        for (final export in fragment.libraryExports) export.exportedLibrary,
      ];
      for (final neighbor in neighbors) {
        if (neighbor == null) continue;
        final uri = neighbor.uri;
        if (uri.scheme == 'dart' &&
            (uri.path == 'ffi' || uri.path == 'mirrors')) {
          throw BuildException(
            "package '${package.name}' imports dart:${uri.path} "
            '(via ${fragment.source.fullName}), which cannot be compiled '
            'to JavaScript or WebAssembly. This package cannot be built.',
          );
        }
        if (uri.scheme == 'dart' && uri.path == 'io') {
          stderr.writeln(
            'warning: ${fragment.source.fullName} imports dart:io — only '
            'partially shimmed on the Node target; do not assume it works.',
          );
        }
        // Only recurse into this package's own libraries.
        if (uri.scheme == 'package' &&
            uri.pathSegments.isNotEmpty &&
            uri.pathSegments.first == package.name) {
          queue.add(neighbor);
        }
      }
    }
  }
}

FunctionApi _lowerFunction(
  ExecutableElement element, {
  required String kind,
  String? owner,
}) {
  final name = element.name ?? '';
  final label = owner == null ? "$kind '$name'" : "$kind '$owner.$name'";

  if (_tsReservedWords.contains(name)) {
    throw UnsupportedApiException(
      "$label — the name is a reserved word in TypeScript",
      file: _fileOf(element),
      line: _lineOf(element),
      hint: 'rename the declaration.',
    );
  }
  if (element.typeParameters.isNotEmpty) {
    throw UnsupportedApiException(
      'generic $label',
      file: _fileOf(element),
      line: _lineOf(element),
      hint:
          'type parameters do not cross the boundary; '
          'runtime generic checks cannot be preserved in TypeScript.',
    );
  }

  final parameters = <ParameterApi>[];
  for (final parameter in element.formalParameters) {
    final parameterName = parameter.name ?? '';
    if (parameter.isNamed) {
      throw UnsupportedApiException(
        "named parameter '$parameterName' of $label",
        file: _fileOf(element),
        line: _lineOf(element),
        hint: 'named parameters (options object) are planned for Phase 2.',
      );
    }
    if (parameter.isOptional) {
      throw UnsupportedApiException(
        "optional parameter '$parameterName' of $label",
        file: _fileOf(element),
        line: _lineOf(element),
        hint: 'optional parameters are planned for Phase 2.',
      );
    }
    parameters.add(
      ParameterApi(
        name: parameterName,
        type: _lowerType(
          parameter.type,
          context: "parameter '$parameterName' of $label",
          element: element,
          allowVoid: false,
        ),
      ),
    );
  }

  return FunctionApi(
    name: name,
    parameters: parameters,
    returnType: _lowerType(
      element.returnType,
      context: 'return type of $label',
      element: element,
      allowVoid: true,
    ),
    documentation: element.documentationComment,
  );
}

ClassApi _lowerClass(ClassElement element) {
  final className = element.name ?? '';
  final file = _fileOf(element);
  final line = _lineOf(element);

  if (element.typeParameters.isNotEmpty) {
    throw UnsupportedApiException(
      "generic class '$className'",
      file: file,
      line: line,
      hint:
          'Dart reifies generics, TypeScript erases them — generic classes '
          'are out of scope for the boundary.',
    );
  }
  if (!element.isConstructable) {
    throw UnsupportedApiException(
      "abstract/sealed class '$className'",
      file: file,
      line: line,
    );
  }
  final extendsNonObject = !(element.supertype?.isDartCoreObject ?? true);
  if (extendsNonObject ||
      element.mixins.isNotEmpty ||
      element.interfaces.isNotEmpty) {
    throw UnsupportedApiException(
      "class '$className' uses inheritance (extends/with/implements)",
      file: file,
      line: line,
      hint:
          'class hierarchies are planned for Phase 3; '
          'Phase 1 supports simple data classes only.',
    );
  }

  // Constructor: exactly the public unnamed one.
  ConstructorElement? unnamed;
  for (final constructor in element.constructors) {
    final ctorName = constructor.name ?? 'new';
    if (ctorName.startsWith('_')) continue;
    if (ctorName == 'new' || ctorName.isEmpty) {
      unnamed = constructor;
    } else {
      throw UnsupportedApiException(
        "named constructor '$className.$ctorName'",
        file: _fileOf(constructor),
        line: _lineOf(constructor),
        hint: 'named constructors are planned for Phase 3.',
      );
    }
  }
  if (unnamed == null) {
    throw UnsupportedApiException(
      "class '$className' has no public unnamed constructor",
      file: file,
      line: line,
    );
  }

  final constructorParameters = <ParameterApi>[];
  for (final parameter in unnamed.formalParameters) {
    final parameterName = parameter.name ?? '';
    if (parameter.isNamed || parameter.isOptional) {
      throw UnsupportedApiException(
        "${parameter.isNamed ? 'named' : 'optional'} constructor parameter "
        "'$parameterName' of class '$className'",
        file: _fileOf(unnamed),
        line: _lineOf(unnamed),
        hint: 'planned for Phase 2 (options object).',
      );
    }
    constructorParameters.add(
      ParameterApi(
        name: parameterName,
        type: _lowerType(
          parameter.type,
          context: "constructor parameter '$parameterName' of '$className'",
          element: unnamed,
          allowVoid: false,
        ),
      ),
    );
  }

  // Properties: non-synthetic instance fields, plus explicit getters
  // (readonly unless a matching explicit setter exists).
  final properties = <PropertyApi>[];
  for (final field in element.fields) {
    if (field.isSynthetic || field.isStatic) continue;
    final fieldName = field.name ?? '';
    if (fieldName.startsWith('_')) continue;
    _checkMemberName(fieldName, className, field);
    properties.add(
      PropertyApi(
        name: fieldName,
        type: _lowerType(
          field.type,
          context: "field '$className.$fieldName'",
          element: field,
          allowVoid: false,
        ),
        isReadonly: field.isFinal || field.isConst,
        documentation: field.documentationComment,
      ),
    );
  }
  final setterNames = {
    for (final setter in element.setters)
      if (!setter.isSynthetic && !setter.isStatic)
        setter.name?.replaceAll('=', ''),
  };
  for (final getter in element.getters) {
    if (getter.isSynthetic || getter.isStatic) continue;
    final getterName = getter.name ?? '';
    if (getterName.startsWith('_')) continue;
    _checkMemberName(getterName, className, getter);
    properties.add(
      PropertyApi(
        name: getterName,
        type: _lowerType(
          getter.returnType,
          context: "getter '$className.$getterName'",
          element: getter,
          allowVoid: false,
        ),
        isReadonly: !setterNames.contains(getterName),
        documentation: getter.documentationComment,
      ),
    );
  }
  for (final setter in element.setters) {
    if (setter.isSynthetic || setter.isStatic) continue;
    final setterName = (setter.name ?? '').replaceAll('=', '');
    final hasGetter = properties.any((property) => property.name == setterName);
    if (!hasGetter) {
      throw UnsupportedApiException(
        "write-only setter '$className.$setterName' (no matching getter)",
        file: _fileOf(setter),
        line: _lineOf(setter),
      );
    }
  }

  // Methods.
  final methods = <FunctionApi>[];
  for (final method in element.methods) {
    final methodName = method.name ?? '';
    if (methodName.startsWith('_')) continue;
    if (method.isStatic) {
      throw UnsupportedApiException(
        "static member '$className.$methodName'",
        file: _fileOf(method),
        line: _lineOf(method),
        hint:
            'static members are planned for Phase 3; '
            'expose a top-level function for now.',
      );
    }
    if (method.isOperator) {
      throw UnsupportedApiException(
        "operator '$className.$methodName'",
        file: _fileOf(method),
        line: _lineOf(method),
      );
    }
    _checkMemberName(methodName, className, method);
    methods.add(_lowerFunction(method, kind: 'method', owner: className));
  }

  return ClassApi(
    name: className,
    constructorParameters: constructorParameters,
    properties: properties,
    methods: methods,
    documentation: element.documentationComment,
  );
}

void _checkMemberName(String name, String className, Element element) {
  if (_reservedMemberNames.contains(name)) {
    throw UnsupportedApiException(
      "member '$className.$name' — the name collides with Object/JS "
      'object plumbing in the generated wrapper',
      file: _fileOf(element),
      line: _lineOf(element),
      hint: 'rename the member.',
    );
  }
}

BoundaryType _lowerType(
  types.DartType type, {
  required String context,
  required Element element,
  required bool allowVoid,
}) {
  if (type is types.VoidType) {
    if (allowVoid) return const VoidType();
    throw UnsupportedApiException(
      'void $context',
      file: _fileOf(element),
      line: _lineOf(element),
    );
  }
  if (type.nullabilitySuffix != NullabilitySuffix.none) {
    throw UnsupportedApiException(
      'nullable type '
      "'${type.getDisplayString()}' in $context",
      file: _fileOf(element),
      line: _lineOf(element),
      hint: 'nullable boundary types are planned for Phase 2 (`T | null`).',
    );
  }
  if (type.isDartCoreString) return const PrimitiveType(PrimitiveKind.string);
  if (type.isDartCoreInt) return const PrimitiveType(PrimitiveKind.intNumber);
  if (type.isDartCoreDouble) {
    return const PrimitiveType(PrimitiveKind.doubleNumber);
  }
  if (type.isDartCoreNum) return const PrimitiveType(PrimitiveKind.numNumber);
  if (type.isDartCoreBool) return const PrimitiveType(PrimitiveKind.boolean);

  final display = type.getDisplayString();
  final String? hint;
  if (type.isDartCoreList || type.isDartCoreMap) {
    hint = 'List/Map marshalling is planned for Phase 2.';
  } else if (type.isDartAsyncFuture) {
    hint = 'Future -> Promise marshalling is planned for Phase 2.';
  } else if (display.startsWith('Stream<')) {
    hint = 'Stream -> AsyncIterable marshalling is planned for Phase 4.';
  } else if (type is types.InterfaceType) {
    hint =
        'class-typed parameters/returns are planned for Phase 3; '
        'Phase 1 supports primitives only.';
  } else {
    hint = null;
  }
  throw UnsupportedApiException(
    "type '$display' in $context",
    file: _fileOf(element),
    line: _lineOf(element),
    hint: hint,
  );
}

void _rejectNameCollisions(
  List<FunctionApi> functions,
  List<ClassApi> classes,
) {
  final seen = <String, String>{};
  void claim(String name, String description) {
    final previous = seen[name];
    if (previous != null) {
      throw BuildException(
        "export name collision: $description would be exported as '$name', "
        'which is already taken by $previous. Rename one of the two.',
      );
    }
    seen[name] = description;
  }

  for (final function in functions) {
    claim(function.name, "function '${function.name}'");
  }
  for (final classApi in classes) {
    claim(
      classApi.factoryName,
      "the generated factory for class '${classApi.name}'",
    );
  }
}

String? _fileOf(Element element) =>
    element.firstFragment.libraryFragment?.source.fullName;

int? _lineOf(Element element) {
  final fragment = element.firstFragment;
  final libraryFragment = fragment.libraryFragment;
  final offset = fragment.nameOffset;
  if (libraryFragment == null || offset == null) return null;
  return libraryFragment.lineInfo.getLocation(offset).lineNumber;
}
