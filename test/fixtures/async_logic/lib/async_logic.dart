/// Fixture: Phase 3/4 surface — callbacks (both directions, sync and
/// async) and runtime `Stream` <-> `AsyncIterable` marshalling.
library;

import 'dart:async';

/// Applies a JS-supplied callback twice (JS function -> Dart function).
int applyTwice(int seed, int Function(int) transform) =>
    transform(transform(seed));

/// Awaits an async (Promise-returning) callback.
Future<String> greetVia(Future<String> Function(String) loader) =>
    loader('Francesco');

/// Returns a function to JS (Dart function -> JS function).
int Function(int) makeAdder(int base) => (value) => base + value;

/// A callback that receives a class instance (handles in callbacks).
String describeVia(Ticket ticket, String Function(Ticket) formatter) =>
    formatter(ticket);

/// Emits `1..count` with a small delay (Dart stream -> JS AsyncIterable).
Stream<int> counter(int count) async* {
  for (var i = 1; i <= count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    yield i;
  }
}

/// Sums a JS async iterable (JS AsyncIterable -> Dart stream).
Future<int> total(Stream<int> values) => values.fold(0, (a, b) => a + b);

/// Streams of class instances.
Stream<Ticket> issueTickets(List<String> owners) =>
    Stream.fromIterable([for (final o in owners) Ticket(o)]);

/// A simple resource with a stream-bearing contract.
class Ticket {
  Ticket(this.owner);

  final String owner;

  String describe() => 'ticket for $owner';
}

/// A Stream-bearing abstract contract: since Phase 4 it has a runtime
/// wrapper too (instances returned by Dart are fully usable).
abstract class TicketFeed {
  Stream<Ticket> watch();

  Future<void> close();
}

/// Returns a concrete [TicketFeed] through the abstract type.
TicketFeed feedOf(List<String> owners) => _ListFeed(owners);

class _ListFeed implements TicketFeed {
  _ListFeed(this.owners);

  final List<String> owners;

  @override
  Stream<Ticket> watch() => issueTickets(owners);

  @override
  Future<void> close() async {}
}
