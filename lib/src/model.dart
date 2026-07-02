/// Intermediate representation of a target package's public API.
///
/// This model is the single source of truth shared by the facade generator
/// (Dart `dart:js_interop` code) and the `.d.ts` generator (TypeScript
/// declarations). It describes the *marshalled boundary* — the
/// js_interop-compatible subset — not raw Dart types.
///
/// The type hierarchy is sealed on purpose: adding a new boundary type
/// (List, Map, Future, Stream, class references, ...) in later phases forces
/// every `switch` in the generators to handle it, so nothing can be emitted
/// silently wrong.
library;

/// A type that crosses the Dart/JS boundary.
sealed class BoundaryType {
  const BoundaryType();

  /// How the type is spelled in the generated Dart facade.
  String get dartSource;

  /// How the type is spelled in the generated TypeScript declarations.
  String get tsSource;
}

/// The js_interop-compatible primitives.
///
/// Note the deliberate information loss: `int`, `double` and `num` all
/// collapse to the JS `number`. 64-bit integer semantics do NOT survive the
/// boundary (JS numbers are IEEE-754 doubles); this is documented, not hidden.
enum PrimitiveKind {
  string('String', 'string'),
  intNumber('int', 'number'),
  doubleNumber('double', 'number'),
  numNumber('num', 'number'),
  boolean('bool', 'boolean');

  const PrimitiveKind(this.dartSource, this.tsSource);

  final String dartSource;
  final String tsSource;
}

final class PrimitiveType extends BoundaryType {
  const PrimitiveType(this.kind);

  final PrimitiveKind kind;

  @override
  String get dartSource => kind.dartSource;

  @override
  String get tsSource => kind.tsSource;
}

/// `void` — valid only as a return type.
final class VoidType extends BoundaryType {
  const VoidType();

  @override
  String get dartSource => 'void';

  @override
  String get tsSource => 'void';
}

/// A single (required, positional) parameter.
final class ParameterApi {
  const ParameterApi({required this.name, required this.type});

  final String name;
  final BoundaryType type;
}

/// A callable: top-level function or instance method.
final class FunctionApi {
  const FunctionApi({
    required this.name,
    required this.parameters,
    required this.returnType,
    this.documentation,
  });

  final String name;
  final List<ParameterApi> parameters;
  final BoundaryType returnType;

  /// Raw Dart doc comment (`///` lines), carried into the `.d.ts` as JSDoc.
  final String? documentation;
}

/// A readable (and possibly writable) instance property: a Dart field, or an
/// explicit getter (+ optional setter).
final class PropertyApi {
  const PropertyApi({
    required this.name,
    required this.type,
    required this.isReadonly,
    this.documentation,
  });

  final String name;
  final BoundaryType type;
  final bool isReadonly;
  final String? documentation;
}

/// A simple data class exposed as an opaque handle: constructed through a
/// generated factory function, used through generated property/method
/// wrappers. The instance is NOT a plain JS object of the original class.
final class ClassApi {
  const ClassApi({
    required this.name,
    required this.constructorParameters,
    required this.properties,
    required this.methods,
    this.documentation,
  });

  final String name;

  /// Parameters of the public unnamed constructor.
  final List<ParameterApi> constructorParameters;

  final List<PropertyApi> properties;
  final List<FunctionApi> methods;
  final String? documentation;

  /// Name of the generated factory function exported to JS/TS
  /// (`Person` -> `createPerson`).
  String get factoryName => 'create$name';
}

/// The complete public API of the target package, post-marshalling.
final class ApiModel {
  const ApiModel({
    required this.dartPackageName,
    required this.libraryUri,
    required this.functions,
    required this.classes,
  });

  /// Pub package name of the target (e.g. `hello_logic`).
  final String dartPackageName;

  /// The public entrypoint library the API was read from
  /// (e.g. `package:hello_logic/hello_logic.dart`).
  final String libraryUri;

  final List<FunctionApi> functions;
  final List<ClassApi> classes;

  /// Every name exported from the npm package, in declaration order.
  List<String> get exportedNames => [
    for (final f in functions) f.name,
    for (final c in classes) c.factoryName,
  ];
}
