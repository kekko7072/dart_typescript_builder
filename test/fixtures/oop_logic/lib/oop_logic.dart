/// Fixture: Phase 3 surface — enums (string-literal unions) and class
/// hierarchies (interface `extends`, polymorphic wrapper dispatch,
/// mixin flattening).
library;

/// Traffic-light colors.
enum Signal { red, amber, green }

/// Enhanced enum: values still cross by name; members stay Dart-side.
enum Priority {
  low(1),
  high(10);

  const Priority(this.weight);

  final int weight;
}

/// The next signal in the cycle.
Signal nextSignal(Signal current) => switch (current) {
  Signal.red => Signal.green,
  Signal.green => Signal.amber,
  Signal.amber => Signal.red,
};

/// Nullable enums cross as `"..." | null`.
Signal? parseSignal(String? name) => switch (name) {
  'red' => Signal.red,
  'amber' => Signal.amber,
  'green' => Signal.green,
  _ => null,
};

/// Priorities of all given labels (enums inside collections).
List<Priority> prioritize(Map<String, bool> flags) => [
  for (final urgent in flags.values) urgent ? Priority.high : Priority.low,
];

/// Base of the hierarchy.
abstract class Animal {
  /// The animal's name.
  String get name;

  /// What it says.
  String speak();
}

mixin _Tagged {
  final List<String> tags = [];

  /// Adds a tag (mixin member, folded into the class interface).
  void tag(String value) => tags.add(value);
}

/// A dog: `extends` in TypeScript, dispatched wrapper at runtime.
class Dog with _Tagged implements Animal {
  Dog(this.name);

  @override
  final String name;

  @override
  String speak() => 'woof';

  /// Dog-only API.
  String fetch() => '$name fetches!';
}

/// Deeper level of the hierarchy.
class Puppy extends Dog {
  Puppy(super.name);

  @override
  String speak() => 'yip';
}

/// Returns an [Animal]-typed value whose runtime type is more derived:
/// the wrapper must expose the most-derived exported interface.
Animal adopt(String kind, String name) => switch (kind) {
  'puppy' => Puppy(name),
  _ => Dog(name),
};

/// A kennel demonstrates supertype-typed collections.
class Kennel {
  Kennel();

  final List<Animal> residents = [];

  void admit(Animal animal) => residents.add(animal);

  /// Everyone speaks (polymorphic dispatch on the Dart side).
  List<String> chorus() => [for (final a in residents) a.speak()];
}
