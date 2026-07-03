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
  String get tsSourceNested =>
      isNullable ? '($tsSourceCore | null)' : tsSourceCore;

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

/// `dynamic`, `Object` and `Object?`: deep-converted passthrough, typed
/// `unknown` on the TypeScript side.
///
/// Marshalled by a generated deep converter: null, bool, num, String,
/// List, String-keyed Map, DateTime (per [DateTimeMode]) and instances of
/// exported classes survive the boundary; anything else fails at runtime
/// with a clear ArgumentError. Numbers arriving from JS are normalized:
/// whole values become Dart `int`, fractional become `double` (matching
/// dart2js/web semantics on both engines).
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
  String get dartSourceCore =>
      dartSpelling == 'Object?' ? 'Object' : dartSpelling;

  @override
  String get dartSource => dartSpelling;

  @override
  String get mangledCore => dartSpelling == 'Object' ? 'Obj' : 'Dyn';

  @override
  String get mangled => mangledCore;
}

final class ListType extends BoundaryType {
  const ListType(
    this.element, {
    super.isNullable = false,
    this.isIterable = false,
  });

  final BoundaryType element;

  /// True when the Dart declaration is `Iterable<T>` rather than `List<T>`
  /// — marshalling is identical (a Dart `List` satisfies `Iterable`), only
  /// the Dart spelling differs.
  final bool isIterable;

  @override
  String get tsSourceCore => '${element.tsSourceNested}[]';

  @override
  String get dartSourceCore =>
      '${isIterable ? 'Iterable' : 'List'}<${element.dartSource}>';

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

/// How Dart `DateTime` crosses the boundary.
enum DateTimeMode {
  /// JS `Date`, via epoch milliseconds (microseconds truncated).
  jsDate('js-date'),

  /// Firestore `Timestamp` from `firebase-admin/firestore` (peer dependency)
  /// — full microsecond fidelity via seconds+nanoseconds. For TypeScript
  /// backends running on Firebase.
  firestoreTimestamp('firestore');

  const DateTimeMode(this.id);

  final String id;

  static DateTimeMode parse(String value) => switch (value) {
    'js-date' || 'date' => DateTimeMode.jsDate,
    'firestore' ||
    'firestore-timestamp' ||
    'timestamp' => DateTimeMode.firestoreTimestamp,
    _ => throw ArgumentError.value(
      value,
      'datetime',
      "expected 'js-date' or 'firestore'",
    ),
  };
}

/// Dart `DateTime` <-> JS `Date` or Firestore `Timestamp`, per [mode].
///
/// A `DateTime` arriving in Dart is always reconstructed as UTC (both JS
/// `Date` and Firestore `Timestamp` are plain instants; Dart's local/UTC
/// flag does not survive the boundary).
final class DateTimeType extends BoundaryType {
  const DateTimeType({required this.mode, super.isNullable = false});

  final DateTimeMode mode;

  @override
  String get tsSourceCore => switch (mode) {
    DateTimeMode.jsDate => 'Date',
    DateTimeMode.firestoreTimestamp => 'Timestamp',
  };

  @override
  String get dartSourceCore => 'DateTime';

  @override
  String get mangledCore => 'Date';
}

/// `Stream<T>` — TYPE-ONLY: it may appear solely in members of type-only
/// (abstract, never-marshalled) classes, where it is declared as
/// `AsyncIterable<T>` for TypeScript implementers. There is no runtime
/// marshalling for streams yet (Phase 4).
final class StreamType extends BoundaryType {
  const StreamType(this.value, {super.isNullable = false});

  final BoundaryType value;

  @override
  String get tsSourceCore => 'AsyncIterable<${value.tsSource}>';

  @override
  String get dartSourceCore => 'Stream<${value.dartSource}>';

  @override
  String get mangledCore => 'StreamOf${value.mangled}';
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
    required this.isTypeOnly,
    required this.constructorParameters,
    required this.properties,
    required this.methods,
    this.staticCallables = const [],
    this.staticProperties = const [],
    this.documentation,
  });

  final String name;

  /// Abstract classes get no factory function; instances returned by other
  /// APIs are still fully usable, and the TS declaration lets consumers type
  /// their own implementations.
  final bool isAbstract;

  /// Type-only classes (abstract contracts using `Stream` members) exist
  /// purely as TypeScript interfaces: no wrapper is generated and their
  /// instances can never cross the boundary at runtime.
  final bool isTypeOnly;

  /// Parameters of the public unnamed constructor (empty when [isAbstract]).
  final List<ParameterApi> constructorParameters;

  final List<PropertyApi> properties;
  final List<FunctionApi> methods;

  /// Static methods, named constructors and factories — exported as callables
  /// on a `ClassName` namespace object (`X.fromMap(...)`).
  final List<FunctionApi> staticCallables;

  /// Static `const`/`final` fields and static getters — exported as *live*
  /// getter properties on the namespace object (re-evaluated per access, so
  /// impure getters like `initialiseJSON` with `DateTime.now()` stay
  /// correct).
  final List<PropertyApi> staticProperties;

  final String? documentation;

  /// Name of the generated factory function for the unnamed constructor
  /// (`Person` -> `createPerson`).
  String get factoryName => 'create$name';

  /// Whether a `ClassName` namespace value is exported alongside the
  /// interface type.
  bool get hasStaticsNamespace =>
      staticCallables.isNotEmpty || staticProperties.isNotEmpty;
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

  /// Every boundary type mentioned anywhere in the API, recursively
  /// (composite types yield themselves and their components).
  Iterable<BoundaryType> get allTypes sync* {
    Iterable<BoundaryType> expand(BoundaryType t) sync* {
      yield t;
      switch (t) {
        case ListType(:final element):
          yield* expand(element);
        case MapType(:final value):
          yield* expand(value);
        case FutureType(:final value):
          yield* expand(value);
        case StreamType(:final value):
          yield* expand(value);
        case PrimitiveType() ||
            VoidType() ||
            DynamicType() ||
            DateTimeType() ||
            ClassRefType():
          break;
      }
    }

    Iterable<BoundaryType> expandFunction(FunctionApi f) sync* {
      yield* expand(f.returnType);
      for (final p in f.parameters) {
        yield* expand(p.type);
      }
    }

    for (final c in constants) {
      yield* expand(c.type);
    }
    for (final f in functions) {
      yield* expandFunction(f);
    }
    for (final c in classes) {
      for (final p in c.constructorParameters) {
        yield* expand(p.type);
      }
      for (final prop in c.properties) {
        yield* expand(prop.type);
      }
      for (final m in c.methods) {
        yield* expandFunction(m);
      }
      for (final s in c.staticCallables) {
        yield* expandFunction(s);
      }
      for (final s in c.staticProperties) {
        yield* expand(s.type);
      }
    }
  }

  /// Whether any `DateTime` crosses as a Firestore `Timestamp` (drives the
  /// firebase-admin peer dependency and the `.d.ts` import).
  bool get usesFirestoreTimestamp => allTypes.any(
    (t) => t is DateTimeType && t.mode == DateTimeMode.firestoreTimestamp,
  );
}
