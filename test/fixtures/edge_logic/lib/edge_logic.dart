/// Fixture: hostile-name and edge-case regression surface for the
/// generated facade / `.d.ts` (adversarial-review findings).
library;

/// Matches glob patterns like **/*.dart against [path].
bool looksLikeDart(String path) => path.endsWith('.dart');

/** Block-style doc with a closing marker inside: end */
int blockDocumented(int x) => x + 1;

/// Reserved-word positional parameter (renamed to a safe label in the
/// declarations; calls are positional).
int count(int delete) => delete * 2;

/// Guards against silent integer clamping beyond 2^53.
int addOne(int value) => value + 1;

/// Returns a self-referential map: must fail loudly, not overflow.
Map<String, dynamic> cyclic() {
  final map = <String, dynamic>{};
  map['self'] = map;
  return map;
}

/// `$` is legal in Dart identifiers and must not interpolate against
/// facade locals; `toString` as an OPTION name must use own-property
/// lookup.
class Foo {
  Foo(this.x);

  int x;

  String foo$wrapper() => 'dollar-ok:$x';

  int describe({required int toString}) => x + toString;

  /// A map with a key literally named `__proto__` must not pollute the
  /// resulting JS object's prototype.
  Map<String, int> protoMap() => {'__proto__': 1, 'ok': 2};
}

/// Generated wrapper names must not collide with [Foo]'s cache
/// (`_wrapCache_Foo` vs `_wrap_CacheFoo`).
class CacheFoo {
  CacheFoo(this.y);

  final int y;
}

/// Abstract with a public unnamed factory: constructable, gets a
/// `createShape` factory.
abstract class Shape {
  factory Shape(int sides) = _Polygon;

  int get sides;

  String describe();
}

class _Polygon implements Shape {
  _Polygon(this.sides);

  @override
  final int sides;

  @override
  String describe() => 'polygon($sides)';
}
