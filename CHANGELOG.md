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
