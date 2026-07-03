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
///
/// `then` is reserved for a subtler reason: a wrapper exposing a callable
/// `then` property is a JS *thenable*, and the Promise resolution procedure
/// would assimilate it — every `Future<ThatClass>` await would call the
/// user's method instead of resolving with the handle.
const _reservedMemberNames = {
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
  'constructor',
  'then',
  '__proto__',
  '__dtb_handle__',
};

/// TypeScript/JS reserved words (including strict-mode and module-context
/// ones — the generated ESM entry runs in strict mode): these cannot be
/// `export function` / `export const` names (object *members* may use them
/// freely).
const _tsReservedWords = {
  // Strict-mode / contextual additions.
  'let', 'static', 'yield', 'await', 'arguments', 'eval',
  'implements', 'interface', 'package', 'private', 'protected', 'public',
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

/// Default values the facade can inline verbatim: literals only, no
/// identifiers that would resolve against the wrong scope. Collection
/// defaults must be UNTYPED (`[]`/`{}`): explicit type arguments could name
/// package-local types that do not resolve inside the prefixed facade; the
/// facade binds defaults through a typed local, so untyped literals get
/// their element types from context.
final _inlinableDefault = RegExp(
  r'''^(null|true|false|-?\d+(\.\d+)?([eE][+-]?\d+)?|0x[0-9a-fA-F]+|'[^'$\\]*'|"[^"$\\]*"|(const\s+)?\[\]|(const\s+)?\{\})$''',
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
///
/// [dateTimeMode] selects how `DateTime` crosses the boundary (JS `Date` or
/// Firestore `Timestamp`).
Future<ApiModel> analyzePackage(
  TargetPackageInfo package, {
  DateTimeMode dateTimeMode = DateTimeMode.jsDate,
}) async {
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
  final lowerer = _Lowerer(exportedClasses, dateTimeMode);

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
          hint:
              'computed getters are evaluated once at module load; '
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
  _rejectRuntimeReferencesToTypeOnlyClasses(api);
  _rejectDateTimeNameShadowing(api, dateTimeMode);
  return api;
}

/// An exported class named like the TypeScript type used for `DateTime`
/// would shadow it inside the generated `.d.ts`.
void _rejectDateTimeNameShadowing(ApiModel api, DateTimeMode mode) {
  if (!api.allTypes.any((t) => t is DateTimeType)) return;
  final reserved = switch (mode) {
    DateTimeMode.jsDate => 'Date',
    DateTimeMode.firestoreTimestamp => 'Timestamp',
  };
  if (api.classByName(reserved) != null) {
    throw BuildException(
      "an exported class is named '$reserved', which collides with the "
      'TypeScript type used for Dart DateTime in ${mode.id} mode. Rename '
      'the class or use the other --datetime mode.',
    );
  }
}

/// Type-only classes (Stream-using abstract contracts) exist purely in the
/// `.d.ts`; nothing that runs at runtime may reference them.
void _rejectRuntimeReferencesToTypeOnlyClasses(ApiModel api) {
  final typeOnly = {
    for (final c in api.classes)
      if (c.isTypeOnly) c.name,
  };
  if (typeOnly.isEmpty) return;

  void walk(BoundaryType type, String where) {
    switch (type) {
      case ClassRefType(:final className):
        if (typeOnly.contains(className)) {
          throw BuildException(
            "$where references class '$className', which is type-only "
            '(it declares Stream members and cannot cross the boundary at '
            'runtime). Remove the reference or drop the Stream members.',
          );
        }
      case ListType(:final element):
        walk(element, where);
      case MapType(:final value):
        walk(value, where);
      case FutureType(:final value):
        walk(value, where);
      case StreamType(:final value):
        walk(value, where);
      case PrimitiveType() || VoidType() || DynamicType() || DateTimeType():
        break;
    }
  }

  void walkFunction(FunctionApi f, String where) {
    walk(f.returnType, where);
    for (final p in f.parameters) {
      walk(p.type, where);
    }
  }

  for (final constant in api.constants) {
    walk(constant.type, "top-level constant '${constant.name}'");
  }
  for (final f in api.functions) {
    walkFunction(f, "function '${f.name}'");
  }
  for (final c in api.classes) {
    // Instance members of type-only classes are themselves type-only.
    if (!c.isTypeOnly) {
      for (final p in c.constructorParameters) {
        walk(p.type, "constructor of '${c.name}'");
      }
      for (final prop in c.properties) {
        walk(prop.type, "property '${c.name}.${prop.name}'");
      }
      for (final m in c.methods) {
        walkFunction(m, "method '${c.name}.${m.name}'");
      }
    }
    // Statics are runtime even on type-only classes.
    for (final s in c.staticCallables) {
      walkFunction(s, "static '${c.name}.${s.name}'");
    }
    for (final s in c.staticProperties) {
      walk(s.type, "static '${c.name}.${s.name}'");
    }
  }
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
  _Lowerer(this._exportedClasses, this._dateTimeMode);

  final Set<ClassElement> _exportedClasses;
  final DateTimeMode _dateTimeMode;

  /// While lowering instance members of an abstract class, `Stream` types
  /// are tolerated (they force the class to become type-only).
  bool _allowStream = false;

  /// Set when a `Stream` was lowered in the current class's instance members.
  bool _sawStream = false;

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
          isRequired:
              parameter.isRequiredPositional || parameter.isRequiredNamed,
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
    _allowStream = false;
    _sawStream = false;

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
    // An abstract class with a public unnamed factory constructor IS
    // constructable — it gets a `createX` factory like a concrete class.
    final hasPublicUnnamedFactory = element.constructors.any((constructor) {
      final ctorName = constructor.name ?? 'new';
      return constructor.isFactory && (ctorName == 'new' || ctorName.isEmpty);
    });
    final isAbstract =
        (element.isAbstract || element.isSealed) && !hasPublicUnnamedFactory;

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

    // Instance members of abstract classes tolerate Stream types — hitting
    // one turns the class into a type-only interface.
    _sawStream = false;
    _allowStream = isAbstract;

    // Properties: non-synthetic instance fields, plus explicit getters
    // (readonly unless a matching explicit setter exists). Static
    // const/final fields and static getters become live namespace
    // properties.
    final properties = <PropertyApi>[];
    final staticProperties = <PropertyApi>[];
    for (final field in element.fields) {
      if (field.isSynthetic) continue;
      final fieldName = field.name ?? '';
      if (fieldName.startsWith('_')) continue;
      _checkMemberName(fieldName, className, field);
      if (field.isStatic) {
        if (!(field.isConst || field.isFinal)) {
          throw UnsupportedApiException(
            "mutable static field '$className.$fieldName'",
            file: _fileOf(field),
            line: _lineOf(field),
            hint:
                'exported statics are read-only on the JS side; make it '
                'const/final or expose accessor methods.',
          );
        }
        _allowStream = false;
        staticProperties.add(
          PropertyApi(
            name: fieldName,
            type: lowerType(
              field.type,
              context: "static field '$className.$fieldName'",
              element: field,
              allowVoid: false,
            ),
            isReadonly: true,
            documentation: field.documentationComment,
          ),
        );
        _allowStream = isAbstract;
      } else {
        properties.add(
          PropertyApi(
            name: fieldName,
            type: lowerType(
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
      _checkMemberName(getterName, className, getter);
      if (getter.isStatic) {
        // Exported as a live getter property on the namespace object, so
        // impure getters are re-evaluated per access.
        _allowStream = false;
        staticProperties.add(
          PropertyApi(
            name: getterName,
            type: lowerType(
              getter.returnType,
              context: "static getter '$className.$getterName'",
              element: getter,
              allowVoid: false,
            ),
            isReadonly: true,
            documentation: getter.documentationComment,
          ),
        );
        _allowStream = isAbstract;
        continue;
      }
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
      if (setter.isSynthetic) continue;
      final setterName = (setter.name ?? '').replaceAll('=', '');
      if (setterName.startsWith('_')) continue;
      if (setter.isStatic) {
        throw UnsupportedApiException(
          "static setter '$className.$setterName'",
          file: _fileOf(setter),
          line: _lineOf(setter),
          hint: 'exported statics are read-only on the JS side; '
              'expose a static method instead.',
        );
      }
      final matchingGetter = element.getters
          .where((g) => !g.isSynthetic && !g.isStatic && g.name == setterName)
          .firstOrNull;
      if (matchingGetter == null) {
        throw UnsupportedApiException(
          "write-only setter '$className.$setterName' (no matching getter)",
          file: _fileOf(setter),
          line: _lineOf(setter),
        );
      }
      // The generated accessor converts the incoming value using the
      // getter's type; a diverging setter type would not compile.
      final setterType = setter.formalParameters.single.type;
      if (setterType != matchingGetter.returnType) {
        throw UnsupportedApiException(
          "getter/setter type mismatch for '$className.$setterName' "
          "(getter is '${matchingGetter.returnType.getDisplayString()}', "
          "setter takes '${setterType.getDisplayString()}')",
          file: _fileOf(setter),
          line: _lineOf(setter),
          hint: 'give both accessors the same type.',
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
        _allowStream = false;
        staticCallables.add(
          lowerFunction(method, kind: 'static method', owner: className),
        );
        _allowStream = isAbstract;
      } else {
        methods.add(lowerFunction(method, kind: 'method', owner: className));
      }
    }

    final isTypeOnly = _sawStream;
    _allowStream = false;
    _sawStream = false;

    return ClassApi(
      name: className,
      isAbstract: isAbstract,
      isTypeOnly: isTypeOnly,
      constructorParameters: constructorParameters,
      properties: properties,
      methods: methods,
      staticCallables: staticCallables,
      staticProperties: staticProperties,
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
        hint:
            'exported values are one-time snapshots; make it const/final '
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
      if (type.isDartCoreList || type.isDartCoreIterable) {
        return ListType(
          lowerType(
            type.typeArguments.single,
            context: 'element type of $context',
            element: element,
            allowVoid: false,
          ),
          isNullable: nullable,
          isIterable: type.isDartCoreIterable,
        );
      }
      if (type.isDartCoreMap) {
        final key = type.typeArguments.first;
        if (!key.isDartCoreString ||
            key.nullabilitySuffix != NullabilitySuffix.none) {
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
        if (_allowStream) {
          // Tolerated only inside abstract-class instance members: the class
          // becomes a type-only TypeScript interface (AsyncIterable typing),
          // never marshalled at runtime.
          _sawStream = true;
          return StreamType(
            lowerType(
              type.typeArguments.single,
              context: 'value type of $context',
              element: element,
              allowVoid: false,
            ),
            isNullable: nullable,
          );
        }
        throw UnsupportedApiException(
          "type '${type.getDisplayString()}' in $context",
          file: _fileOf(element),
          line: _lineOf(element),
          hint:
              'runtime Stream -> AsyncIterable marshalling is planned for '
              'Phase 4 (Streams are currently allowed only in abstract '
              'contract classes, which become type-only interfaces).',
        );
      }

      final interfaceElement = type.element;
      final interfaceLibrary = interfaceElement.library;
      if (interfaceElement.name == 'DateTime' && interfaceLibrary.isDartCore) {
        return DateTimeType(mode: _dateTimeMode, isNullable: nullable);
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
      claim(classApi.name, "the statics namespace of class '${classApi.name}'");
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
