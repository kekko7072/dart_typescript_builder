/// Fixture: function-typed parameters (callbacks) are a later-phase feature.
int apply(int Function(int) transform) => transform(1);
