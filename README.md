<p align="center">
  <img src="logo.png" alt="dart_typescript_builder" width="260">
</p>

# dart_typescript_builder

Write your logic once in Dart. Use it from Flutter **and** from a
TypeScript/Node backend.

This tool compiles a Dart package into an installable npm package: compiled
JS (or WASM), `dart:js_interop` bindings, and generated TypeScript
declarations. It is a bindings generator — think `wasm-pack` for Dart — not a
transpiler: the Dart stays Dart.

## Usage

```sh
dart_typescript_builder build ./my_logic_package --out ./dist --package-name my-logic
```

Then, in your TypeScript backend:

```sh
npm install ./dist
```

```ts
import { createUser, User } from "my-logic";
```

### Options

| Flag             | Values                  | Default                          |
|------------------|-------------------------|----------------------------------|
| `--out`          | directory               | `dist`                           |
| `--engine`       | `dart2js` \| `wasm`     | `dart2js`                        |
| `--module`       | `commonjs` \| `esm`     | `commonjs` (`esm` for wasm)      |
| `--package-name` | npm name                | Dart name with `_` → `-`         |
| `--datetime`     | `js-date` \| `firestore`| `js-date`                        |

The wasm engine is ESM-only and needs Node ≥ 22.

With `--datetime firestore`, Dart `DateTime` crosses as a Firestore
`Timestamp` from `firebase-admin/firestore` (declared as a peer dependency,
microsecond fidelity) — for TypeScript backends running on Firebase. This
also applies to `DateTime` values nested inside `dynamic` data, matching how
the Dart Firebase SDKs treat `toMap()` documents.

## What crosses the boundary

| Dart                     | TypeScript                                    |
|--------------------------|-----------------------------------------------|
| `String`                 | `string`                                      |
| `int`, `double`, `num`   | `number`                                      |
| `bool`                   | `boolean`                                     |
| `T?`                     | `T \| null` (JS `undefined` arrives as null)  |
| `List<T>`, `Iterable<T>` | `T[]`                                         |
| `Map<String, V>`         | `Record<string, V>`                           |
| `Future<T>`              | `Promise<T>`                                  |
| `DateTime`               | `Date` or Firestore `Timestamp` (`--datetime`)|
| `dynamic`, `Object`      | `unknown` (deep-converted JSON-ish snapshot)  |
| named parameters         | trailing options object                       |
| `enum`                   | string-literal union (values cross by name)   |
| function types           | `(p0: T) => R` — callbacks in both directions |
| `Stream<T>`              | `AsyncIterable<T>` (`for await`, early-`break` cancels) |
| class                    | interface + `createX(...)` factory; instances are opaque, identity-cached handles |
| `extends`/`implements`   | `interface X extends Y`; wrappers dispatch to the most-derived class |
| static members, named constructors | callables/live getters on an exported `X` namespace object |
| `abstract class`         | TypeScript interface (no factory)             |
| top-level `const`/`final`| `export const`                                |

⚠️ `int`, `double` and `num` all become JS `number` (IEEE-754 double):
integers beyond 2⁵³ lose precision. `DateTime` arrives in Dart as UTC (the
local/UTC flag doesn't survive). `unknown` payloads are snapshots — send
mutations back via return values.

Anything else — generic classes, records, `FutureOr`, callbacks with named
parameters — fails loudly with `Unsupported: <construct> at <file>:<line>`
instead of emitting broken output.

Boundary validation failures (wrong types, missing required options, foreign
handles) throw real JS `TypeError`s with readable messages on **both**
engines.

## Library API

```dart
import 'package:dart_typescript_builder/dart_typescript_builder.dart';

final result = await buildNpmPackage(BuildOptions(
  packagePath: './my_logic_package',
  outputPath: './dist',
  engine: 'wasm',
  dateTimeMode: DateTimeMode.firestoreTimestamp,
));
```

## Roadmap

1. ✅ Functions + primitives + simple data classes (dart2js & wasm engines)
2. ✅ Collections, `Future`, nullable types, named parameters, `DateTime`
   (JS `Date` / Firestore `Timestamp`), `dynamic` passthrough, class
   references, statics, abstract contracts
3. ✅ Enums, class hierarchies, callbacks
4. ✅ Runtime `Stream` ↔ `AsyncIterable`, nested generics

Next: generic classes, records, TS-implements-Dart-interface direction.

---

Built by [Francesco Vezzani](https://vezz.io) · vezz.io
