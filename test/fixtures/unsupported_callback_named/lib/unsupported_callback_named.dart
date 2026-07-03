/// Fixture: callbacks support required positional parameters only.
int apply(int Function({required int x}) transform) => transform(x: 1);
