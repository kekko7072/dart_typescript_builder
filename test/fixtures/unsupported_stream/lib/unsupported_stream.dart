/// Fixture: Streams outside abstract contracts cannot cross the boundary.
Stream<int> ticks() => const Stream.empty();
