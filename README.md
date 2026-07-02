<p align="center">
  <img src="logo.png" alt="dart_typescript_builder" width="160">
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
import { add, createCounter } from "my-logic";
```

### Options

| Flag             | Values                | Default                          |
|------------------|-----------------------|----------------------------------|
| `--out`          | directory             | `dist`                           |
| `--engine`       | `dart2js` \| `wasm`   | `dart2js`                        |
| `--module`       | `commonjs` \| `esm`   | `commonjs` (`esm` for wasm)      |
| `--package-name` | npm name              | Dart name with `_` → `-`         |

The wasm engine is ESM-only and needs Node ≥ 22.

## What crosses the boundary

| Dart                  | TypeScript      |
|-----------------------|-----------------|
| `String`              | `string`        |
| `int`, `double`, `num`| `number`        |
| `bool`                | `boolean`       |
| simple data class     | opaque handle with typed properties/methods |

⚠️ `int`, `double` and `num` all become JS `number` (IEEE-754 double):
integers beyond 2⁵³ lose precision.

Anything else — collections, `Future`, `Stream`, enums, inheritance, named
parameters — fails loudly with `Unsupported: <construct> at <file>:<line>`
instead of emitting broken output. Collections/async are next on the
[roadmap](#roadmap).

## Library API

```dart
import 'package:dart_typescript_builder/dart_typescript_builder.dart';

final result = await buildNpmPackage(BuildOptions(
  packagePath: './my_logic_package',
  outputPath: './dist',
  engine: 'wasm',
));
```

## Roadmap

1. ✅ Functions + primitives + simple data classes (dart2js & wasm engines)
2. `List`, `Map`, `Future`, nullable types, named parameters
3. Class hierarchies, enums, named constructors, statics
4. `Stream`, nested generics

---

Built by [Francesco Vezzani](https://vezz.io) · vezz.io
