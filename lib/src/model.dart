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

/// `Stream<T>` <-> `AsyncIterable<T>`: outgoing streams become objects
/// implementing the JS async-iteration protocol (`for await` works; an early
/// `break` cancels the Dart subscription); incoming async iterables are
/// pulled into a Dart stream.
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

/// A function type: callbacks cross as JS functions in both directions.
/// Only required positional parameters are supported.
final class CallbackType extends BoundaryType {
  const CallbackType(
    this.parameters,
    this.returnType, {
    super.isNullable = false,
  });

  final List<BoundaryType> parameters;
  final BoundaryType returnType;

  @override
  String get tsSourceCore {
    final params = [
      for (var i = 0; i < parameters.length; i++)
        'p$i: ${parameters[i].tsSource}',
    ].join(', ');
    return '($params) => ${returnType.tsSource}';
  }

  // Function types must always be parenthesized inside composites/unions.
  @override
  String get tsSourceNested =>
      isNullable ? '(($tsSourceCore) | null)' : '($tsSourceCore)';

  @override
  String get dartSourceCore =>
      '${returnType.dartSource} Function('
      '${parameters.map((p) => p.dartSource).join(', ')})';

  @override
  String get mangledCore =>
      'Fn${parameters.map((p) => p.mangled).join('')}To${returnType.mangled}';
}

/// An exported enum: crosses as its value's name (a string-literal union in
/// TypeScript). Enhanced-enum members are Dart-side API only — the identity
/// round-trips, the members do not cross.
final class EnumType extends BoundaryType {
  const EnumType(this.enumName, {super.isNullable = false});

  final String enumName;

  @override
  String get tsSourceCore => enumName;

  @override
  String get dartSourceCore => enumName;

  @override
  String get mangledCore => 'Enum$enumName';
}

/// An exported enum declaration.
final class EnumApi {
  const EnumApi({required this.name, required this.values, this.documentation});

  final String name;

  /// Value names, in declaration order.
  final List<String> values;

  final String? documentation;

  /// The TypeScript union of value-name literals.
  String get tsUnion => values.map((v) => '"$v"').join(' | ');
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
    this.extendsNames = const [],
    this.inheritedProperties = const [],
    this.inheritedMethods = const [],
    this.staticCallables = const [],
    this.staticProperties = const [],
    this.documentation,
  });

  final String name;

  /// Abstract classes get no factory function; instances returned by other
  /// APIs are still fully usable, and the TS declaration lets consumers type
  /// their own implementations.
  final bool isAbstract;

  /// Parameters of the public unnamed constructor (empty when [isAbstract]).
  final List<ParameterApi> constructorParameters;

  /// OWN members (declared on the class or folded in from its unexported
  /// mixins) — these appear in the TypeScript interface body.
  final List<PropertyApi> properties;
  final List<FunctionApi> methods;

  /// Exported ancestors (superclass chain and implemented interfaces): the
  /// TypeScript interface `extends` these.
  final List<String> extendsNames;

  /// Members inherited from exported ancestors: omitted from the TypeScript
  /// interface (they come via `extends`) but present on the runtime wrapper.
  final List<PropertyApi> inheritedProperties;
  final List<FunctionApi> inheritedMethods;

  /// Every member the runtime wrapper must expose.
  List<PropertyApi> get allProperties => [
    ...properties,
    ...inheritedProperties,
  ];
  List<FunctionApi> get allMethods => [...methods, ...inheritedMethods];

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
    this.enums = const [],
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

  /// Exported enums (type-only exports: string-literal unions).
  final List<EnumApi> enums;

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

  EnumApi? enumByName(String name) {
    for (final e in enums) {
      if (e.name == name) return e;
    }
    return null;
  }

  /// Direct exported subclasses of [name] (classes listing it in
  /// [ClassApi.extendsNames]) — drives polymorphic wrapper dispatch.
  List<ClassApi> directSubclassesOf(String name) => [
    for (final c in classes)
      if (c.extendsNames.contains(name)) c,
  ];

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
        case CallbackType(:final parameters, :final returnType):
          for (final p in parameters) {
            yield* expand(p);
          }
          yield* expand(returnType);
        case PrimitiveType() ||
            VoidType() ||
            DynamicType() ||
            DateTimeType() ||
            EnumType() ||
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
