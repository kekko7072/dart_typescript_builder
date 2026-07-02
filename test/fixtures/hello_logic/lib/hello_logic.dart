/// Fixture: Phase 1 surface — top-level functions over primitives plus one
/// simple data class.
library;

/// Adds two integers.
int add(int a, int b) => a + b;

/// Greets [name].
String greet(String name) => 'Hello, $name!';

/// Returns half of [value].
double half(num value) => value / 2;

/// Whether [value] is even.
bool isEven(int value) => value.isEven;

/// A labelled counter.
class Counter {
  Counter(this.label, this.count);

  /// Display label for this counter.
  final String label;

  /// Current count. Mutable from JS.
  int count;

  /// Increments by [by] and returns the new count.
  int increment(int by) => count += by;

  /// Human-readable state.
  String describe() => '$label: $count';

  /// Resets the count to zero.
  void clear() {
    count = 0;
  }
}
