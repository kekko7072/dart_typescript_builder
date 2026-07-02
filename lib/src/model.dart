/// Intermediate representation of a target package's public API.
///
/// This model is the single source of truth shared by the facade generator
/// (Dart `dart:js_interop` code) and the `.d.ts` generator (TypeScript
/// declarations). It describes the *marshalled boundary* — the
/// js_interop-compatible subset — not raw Dart types.
///
/// The type hierarchy is sealed on purpose: adding a new boundary type in
/// later phases forces every `switch` in the generators to handle it, so
/// nothing can be emitted silently wrong.
library;

/// A type that crosses the Dart/JS boundary.
///
/// Nullability is a flag on every type: `T?` crosses as `T | null` (JS
/// `undefined` arriving from the caller is treated as `null`).
sealed class BoundaryType {
  const BoundaryType({required this.isNullable});

  final bool isNullable;

  /// TypeScript spelling *without* the `| null` union.
  String get tsSourceCore;

  /// TypeScript spelling, including `| null` when nullable.
  String get tsSource => isNullable ? '$tsSourceCore | null' : tsSourceCore;

  /// TypeScript spelling safe to embed inside composite types
  /// (`(string | null)[]`).
  String get tsSourceNested => isNullable ? '($tsSourceCore | null)' : tsSourceCore;

  /// The original Dart spelling *without* the trailing `?`.
  String get dartSourceCore;

  /// The original Dart spelling (used for wrapper internals and helper
  /// signatures in the facade).
  String get dartSource => isNullable ? '$dartSourceCore?' : dartSourceCore;

  /// Stable PascalCase name component used to derive facade helper names
  /// (`_toDartListOfNString`), *without* the nullability prefix.
  String get mangledCore;

  /// Stable PascalCase name for this exact type, `N`-prefixed when nullable.
  String get mangled => isNullable ? 'N$mangledCore' : mangledCore;
}

/// The js_interop-compatible primitives.
///
/// Note the deliberate information loss: `int`, `double` and `num` all
/// collapse to the JS `number`. 64-bit integer semantics do NOT survive the
/// boundary (JS numbers are IEEE-754 doubles); this is documented, not hidden.
enum PrimitiveKind {
  string('String', 'string', 'String'),
  intNumber('int', 'number', 'Int'),
  doubleNumber('double', 'number', 'Double'),
  numNumber('num', 'number', 'Num'),
  boolean('bool', 'boolean', 'Bool');

  const PrimitiveKind(this.dartSource, this.tsSource, this.mangled);

  final String dartSource;
  final String tsSource;
  final String mangled;
}

final class PrimitiveType extends BoundaryType {
  const PrimitiveType(this.kind, {super.isNullable = false});

  final PrimitiveKind kind;

  @override
  String get tsSourceCore => kind.tsSource;

  @override
  String get dartSourceCore => kind.dartSource;

  @override
  String get mangledCore => kind.mangled;
}

/// `void` — valid only as a return type.
final class VoidType extends BoundaryType {
  const VoidType() : super(isNullable: false);

  @override
  String get tsSourceCore => 'void';

  @override
  String get dartSourceCore => 'void';

  @override
  String get mangledCore => 'Void';
}

/// `dynamic`, `Object` and `Object?`: JSON-ish passthrough, typed `unknown`
/// on the TypeScript side.
///
/// Marshalled with `jsify()`/`dartify()`: only JSON-compatible values
/// (null, bool, num, String, List, Map) survive the boundary; anything else
/// fails at runtime.
final class DynamicType extends BoundaryType {
  const DynamicType({this.dartSpelling = 'dynamic'})
    : super(isNullable: dartSpelling != 'Object');

  /// `dynamic` | `Object` | `Object?` — preserved so the facade passes the
  /// right static type back into the target API.
  final String dartSpelling;

  @override
  String get tsSourceCore => 'unknown';

  // `unknown` already includes null in TS; never emit `unknown | null`.
  @override
  String get tsSource => 'unknown';

  @override
  String get dartSourceCore => dartSpelling == 'Object?' ? 'Object' : dartSpelling;

  @override
  String get dartSource => dartSpelling;

  @override
  String get mangledCore => dartSpelling == 'Object' ? 'Obj' : 'Dyn';

  @override
  String get mangled => mangledCore;
}

final class ListType extends BoundaryType {
  const ListType(this.element, {super.isNullable = false});

  final BoundaryType element;

  @override
  String get tsSourceCore => '${element.tsSourceNested}[]';

  @override
  String get dartSourceCore => 'List<${element.dartSource}>';

  @override
  String get mangledCore => 'ListOf${element.mangled}';
}

/// `Map<String, V>` — the only supported key type is `String`
/// (JS object keys are strings).
final class MapType extends BoundaryType {
  const MapType(this.value, {super.isNullable = false});

  final BoundaryType value;

  @override
  String get tsSourceCore => 'Record<string, ${value.tsSource}>';

  @override
  String get dartSourceCore => 'Map<String, ${value.dartSource}>';

  @override
  String get mangledCore => 'MapOf${value.mangled}';
}

final class FutureType extends BoundaryType {
  const FutureType(this.value, {super.isNullable = false});

  final BoundaryType value;

  @override
  String get tsSourceCore => 'Promise<${value.tsSource}>';

  @override
  String get dartSourceCore => 'Future<${value.dartSource}>';

  @override
  String get mangledCore => 'FutureOf${value.mangled}';
}

/// Dart `DateTime` <-> JS `Date`.
///
/// Crossing the boundary goes through epoch milliseconds: microseconds are
/// truncated, and a JS `Date` arriving in Dart is reconstructed as UTC (a JS
/// `Date` is a plain instant; Dart's local/UTC flag does not survive).
final class DateTimeType extends BoundaryType {
  const DateTimeType({super.isNullable = false});

  @override
  String get tsSourceCore => 'Date';

  @override
  String get dartSourceCore => 'DateTime';

  @override
  String get mangledCore => 'Date';
}

/// A reference to another class exported by the same package: crosses as the
/// opaque handle produced by that class's generated wrapper.
final class ClassRefType extends BoundaryType {
  const ClassRefType(this.className, {super.isNullable = false});

  final String className;

  @override
  String get tsSourceCore => className;

  @override
  String get dartSourceCore => className;

  @override
  String get mangledCore => 'Ref$className';
}

enum ParameterKind { requiredPositional, optionalPositional, named }

final class ParameterApi {
  const ParameterApi({
    required this.name,
    required this.type,
    this.kind = ParameterKind.requiredPositional,
    this.isRequired = true,
    this.defaultValueCode,
  });

  final String name;
  final BoundaryType type;
  final ParameterKind kind;

  /// True for required positional and `required` named parameters.
  final bool isRequired;

  /// Dart source of the default value — only present when the analyzer
  /// validated it as a safe-to-inline literal.
  final String? defaultValueCode;
}

/// A callable: top-level function, instance method, or static callable
/// (static method / named constructor / factory).
final class FunctionApi {
  const FunctionApi({
    required this.name,
    required this.parameters,
    required this.returnType,
    this.documentation,
  });

  final String name;

  /// Ordered: required positional, optional positional, named.
  final List<ParameterApi> parameters;
  final BoundaryType returnType;

  /// Raw Dart doc comment (`///` lines), carried into the `.d.ts` as JSDoc.
  final String? documentation;

  List<ParameterApi> get requiredPositional => [
    for (final p in parameters)
      if (p.kind == ParameterKind.requiredPositional) p,
  ];

  List<ParameterApi> get optionalPositional => [
    for (final p in parameters)
      if (p.kind == ParameterKind.optionalPositional) p,
  ];

  List<ParameterApi> get named => [
    for (final p in parameters)
      if (p.kind == ParameterKind.named) p,
  ];

  bool get hasOptionsObject => named.isNotEmpty;

  /// Whether the options object itself may be omitted by the caller.
  bool get optionsObjectIsOptional => named.every((p) => !p.isRequired);

  /// Name of the trailing options parameter, dodging positional names.
  String get optionsParameterName {
    var candidate = 'options';
    while (parameters.any((p) => p.name == candidate)) {
      candidate = '$candidate\$';
    }
    return candidate;
  }
}

/// A readable (and possibly writable) property: instance field, explicit
/// getter (+ optional setter), static constant, or top-level constant.
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

/// A class exposed as an opaque handle: constructed through a generated
/// factory function (unless abstract), used through generated
/// property/method wrappers. The instance is NOT a plain JS object.
final class ClassApi {
  const ClassApi({
    required this.name,
    required this.isAbstract,
    required this.constructorParameters,
    required this.properties,
    required this.methods,
    this.staticCallables = const [],
    this.staticConstants = const [],
    this.documentation,
  });

  final String name;

  /// Abstract classes cross as *type-only* interfaces: no factory function is
  /// generated, but instances returned by other APIs are fully usable, and
  /// the TS declaration lets consumers type their own implementations.
  final bool isAbstract;

  /// Parameters of the public unnamed constructor (empty when [isAbstract]).
  final List<ParameterApi> constructorParameters;

  final List<PropertyApi> properties;
  final List<FunctionApi> methods;

  /// Static methods, named constructors and factories — exported as callables
  /// on a `ClassName` namespace object (`X.fromMap(...)`).
  final List<FunctionApi> staticCallables;

  /// Static `const`/`final` fields — exported as values on the namespace
  /// object, converted once at module initialization.
  final List<PropertyApi> staticConstants;

  final String? documentation;

  /// Name of the generated factory function for the unnamed constructor
  /// (`Person` -> `createPerson`).
  String get factoryName => 'create$name';

  /// Whether a `ClassName` namespace value is exported alongside the
  /// interface type.
  bool get hasStaticsNamespace =>
      staticCallables.isNotEmpty || staticConstants.isNotEmpty;
}

/// The complete public API of the target package, post-marshalling.
final class ApiModel {
  const ApiModel({
    required this.dartPackageName,
    required this.libraryUri,
    required this.functions,
    required this.classes,
    this.constants = const [],
  });

  /// Pub package name of the target (e.g. `hello_logic`).
  final String dartPackageName;

  /// The public entrypoint library the API was read from
  /// (e.g. `package:hello_logic/hello_logic.dart`).
  final String libraryUri;

  final List<FunctionApi> functions;
  final List<ClassApi> classes;

  /// Top-level `const`/`final` values, converted once at initialization.
  final List<PropertyApi> constants;

  /// Every name exported from the npm package, in declaration order.
  List<String> get exportedNames => [
    for (final c in constants) c.name,
    for (final f in functions) f.name,
    for (final c in classes) ...[
      if (!c.isAbstract) c.factoryName,
      if (c.hasStaticsNamespace) c.name,
    ],
  ];

  ClassApi? classByName(String name) {
    for (final c in classes) {
      if (c.name == name) return c;
    }
    return null;
  }
}
