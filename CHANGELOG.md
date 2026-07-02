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
