// Fixture: dart:ffi cannot target JS/WASM at all.
import 'dart:ffi';

int pointerSize() => sizeOf<IntPtr>();
