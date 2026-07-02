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
  '__dtb_handle__',
};

/// TypeScript reserved words: these cannot be `export function` /
/// `export const` names (object *members* may use them freely).
const _tsReservedWords = {
  'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger',
  'default', 'delete', 'do', 'else', 'enum', 'export', 'extends', 'false',
  'finally', 'for', 'function', 'if', 'import', 'in', 'instanceof', 'new',
  'null', 'return', 'super', 'switch', 'this', 'throw', 'true', 'try',
  'typeof', 'var', 'void', 'while', 'with',
};

/// Default values the facade can inline verbatim: literals only, no
/// identifiers that would resolve against the wrong scope.
final _inlinableDefault = RegExp(
  r'''^(null|true|false|-?\d+(\.\d+)?([eE][+-]?\d+)?|0x[0-9a-fA-F]+|'[^'$\\]*'|"[^"$\\]*"|(const\s+)?(<[A-Za-z0-9_,<>?\s]+>)?\[\]|(const\s+)?(<[A-Za-z0-9_,<>?\s]+>)?\{\})$''',
);

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

  final names = library.exportNamespace.definedNames2.keys.toList()..sort();

  // Pass 1: collect the exported classes so class references can be resolved
  // while lowering types (including mutual/cyclic references).
  final exportedClasses = <ClassElement>{};
  for (final name in names) {
    final element = library.exportNamespace.definedNames2[name];
    if (element is ClassElement) exportedClasses.add(element);
  }
  final lowerer = _Lowerer(exportedClasses);

  final functions = <FunctionApi>[];
  final classes = <ClassApi>[];
  final constants = <PropertyApi>[];

  for (final name in names) {
    if (name.endsWith('=')) continue; // setter entries; handled with getters
    if (name.startsWith('_')) continue;
    final element = library.exportNamespace.definedNames2[name]!;
    switch (element) {
      case TopLevelFunctionElement():
        functions.add(lowerer.lowerFunction(element, kind: 'function'));
      case ClassElement():
        classes.add(lowerer.lowerClass(element));
      case GetterElement(:final variable)
          when element.isSynthetic && variable is TopLevelVariableElement:
        // Namespaces expose top-level variables through synthetic accessors.
        constants.add(lowerer.lowerTopLevelVariable(variable, name));
      case GetterElement():
        throw UnsupportedApiException(
          "top-level getter '$name'",
          file: _fileOf(element),
          line: _lineOf(element),
          hint: 'computed getters are evaluated once at module load; '
              'expose a function instead.',
        );
      case TopLevelVariableElement():
        constants.add(lowerer.lowerTopLevelVariable(element, name));
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
      case SetterElement():
        continue; // covered by the getter/variable entry
      default:
        throw UnsupportedApiException(
          "declaration '$name' (${element.kind.displayName})",
          file: _fileOf(element),
          line: _lineOf(element),
        );
    }
  }

  final api = ApiModel(
    dartPackageName: package.name,
    libraryUri: package.entryLibraryUri,
    functions: functions,
    classes: classes,
    constants: constants,
  );
  _rejectNameCollisions(api);
  return api;
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

/// Lowers resolved elements/types into the boundary model. Holds the set of
/// exported classes so `ClassRefType`s can be resolved.
final class _Lowerer {
  _Lowerer(this._exportedClasses);

  final Set<ClassElement> _exportedClasses;

  FunctionApi lowerFunction(
    ExecutableElement element, {
    required String kind,
    String? owner,
    BoundaryType? returnTypeOverride,
    String? nameOverride,
  }) {
    final name = nameOverride ?? element.name ?? '';
    final label = owner == null ? "$kind '$name'" : "$kind '$owner.$name'";

    if (kind == 'function' && _tsReservedWords.contains(name)) {
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

    return FunctionApi(
      name: name,
      parameters: lowerParameters(element, label),
      returnType:
          returnTypeOverride ??
          lowerType(
            element.returnType,
            context: 'return type of $label',
            element: element,
            allowVoid: true,
          ),
      documentation: element.documentationComment,
    );
  }

  List<ParameterApi> lowerParameters(ExecutableElement element, String label) {
    final parameters = <ParameterApi>[];
    for (final parameter in element.formalParameters) {
      final parameterName = parameter.name ?? '';
      final type = lowerType(
        parameter.type,
        context: "parameter '$parameterName' of $label",
        element: element,
        allowVoid: false,
      );

      final kind = parameter.isNamed
          ? ParameterKind.named
          : parameter.isOptionalPositional
          ? ParameterKind.optionalPositional
          : ParameterKind.requiredPositional;

      String? defaultCode;
      if (parameter.isOptional) {
        final code = parameter.defaultValueCode;
        if (code != null) {
          if (!_inlinableDefault.hasMatch(code)) {
            throw UnsupportedApiException(
              "default value `$code` of parameter '$parameterName' of $label "
              'is not an inlinable literal',
              file: _fileOf(element),
              line: _lineOf(element),
              hint:
                  'only literal defaults (numbers, strings, booleans, null, '
                  'empty collections) can cross the boundary; make the '
                  'parameter nullable and apply the default inside the '
                  'function instead.',
            );
          }
          defaultCode = code;
        } else if (!type.isNullable) {
          throw UnsupportedApiException(
            "optional parameter '$parameterName' of $label has a "
            'non-nullable type and no default value',
            file: _fileOf(element),
            line: _lineOf(element),
          );
        }
      }

      parameters.add(
        ParameterApi(
          name: parameterName,
          type: type,
          kind: kind,
          isRequired: parameter.isRequiredPositional || parameter.isRequiredNamed,
          defaultValueCode: defaultCode,
        ),
      );
    }
    return parameters;
  }

  ClassApi lowerClass(ClassElement element) {
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
            'flatten the class or hide it from the public API.',
      );
    }
    final isAbstract = element.isAbstract || element.isSealed;

    // Constructors: the public unnamed one becomes the factory function;
    // public named constructors and factories become static callables.
    final staticCallables = <FunctionApi>[];
    ConstructorElement? unnamed;
    for (final constructor in element.constructors) {
      if (constructor.isSynthetic && (element.constructors.length == 1)) {
        unnamed = constructor; // implicit default constructor
        continue;
      }
      final ctorName = constructor.name ?? 'new';
      if (ctorName.startsWith('_')) continue;
      if (ctorName == 'new' || ctorName.isEmpty) {
        unnamed = constructor;
      } else {
        _checkMemberName(ctorName, className, constructor);
        staticCallables.add(
          lowerFunction(
            constructor,
            kind: 'constructor',
            owner: className,
            nameOverride: ctorName,
            returnTypeOverride: ClassRefType(className),
          ),
        );
      }
    }

    final constructorParameters = <ParameterApi>[];
    if (!isAbstract) {
      if (unnamed == null) {
        throw UnsupportedApiException(
          "class '$className' has no public unnamed constructor",
          file: file,
          line: line,
          hint:
              'add one, or mark the class abstract to export it as a '
              'type-only interface.',
        );
      }
      constructorParameters.addAll(
        lowerParameters(unnamed, "constructor of '$className'"),
      );
    }

    // Properties: non-synthetic instance fields, plus explicit getters
    // (readonly unless a matching explicit setter exists). Static
    // const/final fields become namespace constants.
    final properties = <PropertyApi>[];
    final staticConstants = <PropertyApi>[];
    for (final field in element.fields) {
      if (field.isSynthetic) continue;
      final fieldName = field.name ?? '';
      if (fieldName.startsWith('_')) continue;
      _checkMemberName(fieldName, className, field);
      final type = lowerType(
        field.type,
        context: "field '$className.$fieldName'",
        element: field,
        allowVoid: false,
      );
      if (field.isStatic) {
        if (!(field.isConst || field.isFinal)) {
          throw UnsupportedApiException(
            "mutable static field '$className.$fieldName'",
            file: _fileOf(field),
            line: _lineOf(field),
            hint: 'exported statics are one-time snapshots; make it '
                'const/final or expose accessor methods.',
          );
        }
        staticConstants.add(
          PropertyApi(
            name: fieldName,
            type: type,
            isReadonly: true,
            documentation: field.documentationComment,
          ),
        );
      } else {
        properties.add(
          PropertyApi(
            name: fieldName,
            type: type,
            isReadonly: field.isFinal || field.isConst,
            documentation: field.documentationComment,
          ),
        );
      }
    }
    final setterNames = {
      for (final setter in element.setters)
        if (!setter.isSynthetic && !setter.isStatic)
          setter.name?.replaceAll('=', ''),
    };
    for (final getter in element.getters) {
      if (getter.isSynthetic) continue;
      final getterName = getter.name ?? '';
      if (getterName.startsWith('_')) continue;
      if (getter.isStatic) {
        throw UnsupportedApiException(
          "static getter '$className.$getterName'",
          file: _fileOf(getter),
          line: _lineOf(getter),
          hint: 'exported statics are evaluated once at module load; '
              'expose a static method instead.',
        );
      }
      _checkMemberName(getterName, className, getter);
      properties.add(
        PropertyApi(
          name: getterName,
          type: lowerType(
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
      final hasGetter = properties.any(
        (property) => property.name == setterName,
      );
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
      if (method.isOperator) {
        throw UnsupportedApiException(
          "operator '$className.$methodName'",
          file: _fileOf(method),
          line: _lineOf(method),
        );
      }
      _checkMemberName(methodName, className, method);
      if (method.isStatic) {
        staticCallables.add(
          lowerFunction(method, kind: 'static method', owner: className),
        );
      } else {
        methods.add(lowerFunction(method, kind: 'method', owner: className));
      }
    }

    return ClassApi(
      name: className,
      isAbstract: isAbstract,
      constructorParameters: constructorParameters,
      properties: properties,
      methods: methods,
      staticCallables: staticCallables,
      staticConstants: staticConstants,
      documentation: element.documentationComment,
    );
  }

  PropertyApi lowerTopLevelVariable(
    TopLevelVariableElement element,
    String name,
  ) {
    if (!(element.isConst || element.isFinal)) {
      throw UnsupportedApiException(
        "mutable top-level variable '$name'",
        file: _fileOf(element),
        line: _lineOf(element),
        hint: 'exported values are one-time snapshots; make it const/final '
            'or expose functions.',
      );
    }
    if (_tsReservedWords.contains(name)) {
      throw UnsupportedApiException(
        "top-level constant '$name' — the name is a reserved word in "
        'TypeScript',
        file: _fileOf(element),
        line: _lineOf(element),
        hint: 'rename the declaration.',
      );
    }
    return PropertyApi(
      name: name,
      type: lowerType(
        element.type,
        context: "top-level constant '$name'",
        element: element,
        allowVoid: false,
      ),
      isReadonly: true,
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

  BoundaryType lowerType(
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
    if (type is types.DynamicType) return const DynamicType();
    if (type.isDartCoreObject) {
      return DynamicType(
        dartSpelling: type.nullabilitySuffix == NullabilitySuffix.question
            ? 'Object?'
            : 'Object',
      );
    }

    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;

    if (type.isDartCoreString) {
      return PrimitiveType(PrimitiveKind.string, isNullable: nullable);
    }
    if (type.isDartCoreInt) {
      return PrimitiveType(PrimitiveKind.intNumber, isNullable: nullable);
    }
    if (type.isDartCoreDouble) {
      return PrimitiveType(PrimitiveKind.doubleNumber, isNullable: nullable);
    }
    if (type.isDartCoreNum) {
      return PrimitiveType(PrimitiveKind.numNumber, isNullable: nullable);
    }
    if (type.isDartCoreBool) {
      return PrimitiveType(PrimitiveKind.boolean, isNullable: nullable);
    }

    if (type is types.InterfaceType) {
      if (type.isDartCoreList) {
        return ListType(
          lowerType(
            type.typeArguments.single,
            context: 'element type of $context',
            element: element,
            allowVoid: false,
          ),
          isNullable: nullable,
        );
      }
      if (type.isDartCoreMap) {
        final key = type.typeArguments.first;
        if (!key.isDartCoreString) {
          throw UnsupportedApiException(
            "map key type '${key.getDisplayString()}' in $context "
            '(only String keys cross the boundary — JS object keys are '
            'strings)',
            file: _fileOf(element),
            line: _lineOf(element),
          );
        }
        return MapType(
          lowerType(
            type.typeArguments[1],
            context: 'value type of $context',
            element: element,
            allowVoid: false,
          ),
          isNullable: nullable,
        );
      }
      if (type.isDartAsyncFuture) {
        return FutureType(
          lowerType(
            type.typeArguments.single,
            context: 'value type of $context',
            element: element,
            allowVoid: true,
          ),
          isNullable: nullable,
        );
      }
      if (type.isDartAsyncStream) {
        throw UnsupportedApiException(
          "type '${type.getDisplayString()}' in $context",
          file: _fileOf(element),
          line: _lineOf(element),
          hint: 'Stream -> AsyncIterable marshalling is planned for Phase 4.',
        );
      }

      final interfaceElement = type.element;
      final interfaceLibrary = interfaceElement.library;
      if (interfaceElement.name == 'DateTime' && interfaceLibrary.isDartCore) {
        return DateTimeType(isNullable: nullable);
      }
      if (interfaceElement is ClassElement &&
          _exportedClasses.contains(interfaceElement)) {
        return ClassRefType(interfaceElement.name ?? '', isNullable: nullable);
      }
      if (interfaceElement is EnumElement) {
        throw UnsupportedApiException(
          "enum type '${type.getDisplayString()}' in $context",
          file: _fileOf(element),
          line: _lineOf(element),
          hint: 'enums are planned for Phase 3 (string-literal unions).',
        );
      }
      if (interfaceElement is ClassElement &&
          !interfaceLibrary.isInSdk &&
          interfaceLibrary.uri.scheme == 'package') {
        throw UnsupportedApiException(
          "type '${type.getDisplayString()}' in $context — the class is not "
          "exported by the package's public entrypoint",
          file: _fileOf(element),
          line: _lineOf(element),
          hint:
              'export it from the entry library to generate bindings for it, '
              'or hide this member.',
        );
      }
    }

    if (type.isDartAsyncFutureOr) {
      throw UnsupportedApiException(
        "type '${type.getDisplayString()}' in $context (FutureOr has no JS "
        'equivalent)',
        file: _fileOf(element),
        line: _lineOf(element),
      );
    }
    if (type is types.FunctionType) {
      throw UnsupportedApiException(
        "function type '${type.getDisplayString()}' in $context",
        file: _fileOf(element),
        line: _lineOf(element),
        hint: 'callback marshalling is planned for a later phase.',
      );
    }
    if (type is types.RecordType) {
      throw UnsupportedApiException(
        "record type '${type.getDisplayString()}' in $context",
        file: _fileOf(element),
        line: _lineOf(element),
      );
    }

    throw UnsupportedApiException(
      "type '${type.getDisplayString()}' in $context",
      file: _fileOf(element),
      line: _lineOf(element),
    );
  }
}

void _rejectNameCollisions(ApiModel api) {
  final seen = <String, String>{};
  void claim(String name, String description) {
    final previous = seen[name];
    if (previous != null) {
      throw BuildException(
        "export name collision: $description would be exported as '$name', "
        'which is already taken by $previous. Rename one of the two.',
      );
    }
    if (_tsReservedWords.contains(name)) {
      throw BuildException(
        "$description would be exported as '$name', which is a reserved "
        'word in TypeScript. Rename it.',
      );
    }
    seen[name] = description;
  }

  for (final constant in api.constants) {
    claim(constant.name, "top-level constant '${constant.name}'");
  }
  for (final function in api.functions) {
    claim(function.name, "function '${function.name}'");
  }
  for (final classApi in api.classes) {
    if (!classApi.isAbstract) {
      claim(
        classApi.factoryName,
        "the generated factory for class '${classApi.name}'",
      );
    }
    if (classApi.hasStaticsNamespace) {
      claim(
        classApi.name,
        "the statics namespace of class '${classApi.name}'",
      );
    }
  }
}

String? _fileOf(Element element) =>
    element.firstFragment.libraryFragment?.source.fullName;

int? _lineOf(Element element) {
  final fragment = element.firstFragment;
  final libraryFragment = fragment.libraryFragment;
  // Unnamed/implicit constructors have no name of their own; their fragment
  // offset points at the class name instead.
  final offset =
      fragment.nameOffset ??
      (fragment is ConstructorFragment ? fragment.offset : null);
  if (libraryFragment == null || offset == null) return null;
  return libraryFragment.lineInfo.getLocation(offset).lineNumber;
}
