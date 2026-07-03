/// Fixture: generic classes cannot cross (Dart reifies, TS erases).
class Box<T> {
  Box(this.value);
  final T value;
}
