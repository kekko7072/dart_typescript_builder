## 0.4.0

- New `--firestore-types` flag (opt-in, requires `--datetime firestore` —
  the conversion is always an explicit user choice): the full firebase-admin
  Firestore value set crosses inside `dynamic` data. `Buffer`/`Uint8Array`
  (bytes fields) converts to Dart `Uint8List` and back (copied snapshots,
  fresh `Uint8Array` on the way out); `GeoPoint`, `DocumentReference`,
  `FieldValue` sentinels and `VectorValue` pass through opaquely with JS
  identity preserved, so documents containing them survive `fromMap`/`toMap`
  round trips instead of failing at the boundary. Class identities are
  injected by the entry module; `GeoPoint` and document references are also
  duck-typed so values from a different firebase-admin copy still cross.
  Older firebase-admin versions missing an export (e.g. `VectorValue`) are
  tolerated. Available on both engines and from the library API
  (`BuildOptions.firestoreTypes`).
- Regenerated the stale `async_logic` goldens (the 0.3.0 hardening pass
  changed callback helper mangles and callback type parenthesization
  without refreshing them).
- The tomorrowtech acceptance test now builds with `runNpmInstall: false`:
  the default install fetched the real firebase-admin peer into the built
  package, shadowing the offline stub with a second Timestamp class
  identity.

## 0.3.0

Phase 3 + Phase 4. Both engines.

- Enums: exported as string-literal unions (`type Signal = "red" | "amber" |
  "green"`); values cross by name with validated round trips; enhanced-enum
  members stay Dart-side.
- Class hierarchies: `extends`/`implements` between exported classes become
  TypeScript `interface ... extends`; wrappers dispatch polymorphically to
  the most-derived exported class; mixin members are folded into the class
  interface; abstract classes with a public unnamed factory constructor get
  a `createX` factory.
- Callbacks: function-typed parameters and returns cross as JS functions in
  both directions (sync and async/Promise-returning), including class
  handles inside callback signatures.
- Runtime `Stream<T>` <-> `AsyncIterable<T>`: `for await` over Dart streams
  (early `break` cancels the subscription), JS async iterables consumed as
  Dart streams, streams of class handles, and Stream-bearing abstract
  contracts now have runtime wrappers (the type-only workaround is gone).
- When the npm package is generated inside the target package, the target's
  `analysis_options.yaml` automatically gains the exclusion (created with
  `package:lints/recommended.yaml` when absent).
- CI: pinned Dart SDK (deterministic `dart format`), action majors bumped
  off the deprecated Node 20 runtime.

## 0.2.0

Phase 2 + class references + configurable DateTime mapping. Both engines.

- Collections & async: `List<T>`/`Iterable<T>` -> `T[]`, `Map<String, V>` ->
  `Record<string, V>`, `Future<T>` -> `Promise<T>`, nullable types -> `T | null`.
- `dynamic`/`Object` -> `unknown`: hand-rolled deep converter (never
  jsify/dartify — number semantics diverge between engines); whole JS numbers
  normalize to Dart `int` on both engines.
- Named parameters -> trailing options object (required options validated at
  runtime with readable errors); optional positional parameters with
  inlinable literal defaults.
- Class references: instances cross as identity-cached opaque handles
  (`JSBoxedDartObject` brand-checked), usable as parameters, returns, fields,
  inside collections and `dynamic` data.
- Statics: static methods, named constructors and factories exported on a
  `ClassName` namespace object; static getters/consts as live properties.
- Abstract classes -> TypeScript interfaces; Stream-bearing contracts become
  type-only interfaces typed with `AsyncIterable<T>`.
- Top-level `const`/`final` values exported.
- `--datetime js-date|firestore`: `DateTime` as JS `Date`, or as Firestore
  `Timestamp` from `firebase-admin/firestore` (peer dependency, microsecond
  fidelity) for Firebase backends — including `DateTime` values inside
  `dynamic` maps.
- Boundary validation errors surface as real JS `TypeError`s with messages on
  BOTH engines (thrown through an injected JS frame; a bare Dart exception
  escaping dart2wasm is a message-less `WebAssembly.Exception`).
- CommonJS entry emits static named-export hints so ESM consumers can
  name-import the dart2js build.

Hardening from an adversarial review pass (every finding reproduced before
fixing):

- A method named `then` is rejected: the wrapper handle would be a JS
  *thenable* and Promise assimilation would hijack every `Future<ThatClass>`.
- `$` in exported/member names no longer corrupts the generated facade;
  hostile doc comments (`**/*.dart`, block comments) can no longer break the
  generated `.d.ts`; classes named like generated helpers (`Foo`+`CacheFoo`)
  no longer collide; entry-glue locals are collision-proof (`__dtb$` prefix).
- Options lookups use `Object.hasOwn` (an option named `toString` works);
  map keys named `__proto__` are stored as data properties instead of
  mutating the prototype; typed `int`/`num` conversions guard the 2^53 safe
  range; cyclic `dynamic` data fails loudly instead of overflowing the stack.
- Strict-mode reserved words (`let`, `yield`, ...) are rejected as export
  names; reserved-word positional parameter names are relabelled in the
  `.d.ts`; getter/setter type mismatches, static setters, nullable map keys
  and classes shadowing `Date`/`Timestamp` are rejected with clear
  diagnostics; abstract classes with a public unnamed factory constructor
  now get their `createX` factory; npm versions strip Dart build metadata
  instead of becoming prereleases.

## 0.1.0

Initial release — Phase 1 (MVP), both engines.

- Analyze a Dart package's resolved public API (`package:analyzer`): top-level
  functions over `String`/`int`/`double`/`num`/`bool` and simple data classes
  (primitive fields, getters/setters, methods, unnamed constructor).
- Generate an engine-agnostic `dart:js_interop` facade and matching
  TypeScript declarations (`.d.ts`) from the same API model.
- `dart2js` engine: CommonJS or ESM npm package via node_preamble.
- `wasm` engine (`dart compile wasm`): ESM npm package, Node >= 22.
- Everything outside the supported subset fails with
  `Unsupported: <construct> at <file>:<line>` plus a roadmap hint.
