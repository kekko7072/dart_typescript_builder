/// Fixture: the Phase 2 boundary surface — collections, async, DateTime,
/// nullable types, named/optional parameters, class references, statics,
/// dynamic passthrough, constants, and a type-only Stream contract.
library;

/// Default page size used by [search].
const int kDefaultLimit = 10;

/// Supported locales.
const List<String> kLocales = ['en', 'it'];

/// Sums a list of integers.
int sum(List<int> values) => values.fold(0, (a, b) => a + b);

/// Uppercases non-null entries, keeps nulls.
List<String?> shout(List<String?> words) =>
    [for (final w in words) w?.toUpperCase()];

/// Counts characters per word.
Map<String, int> lengths(List<String> words) =>
    {for (final w in words) w: w.length};

/// Echoes arbitrary JSON-ish data, adding a `seen: true` flag to maps.
dynamic annotate(dynamic data) {
  if (data is Map<String, dynamic>) {
    return {...data, 'seen': true};
  }
  return data;
}

/// Returns a greeting after [delayMs] milliseconds.
Future<String> delayedGreet(String name, int delayMs) async {
  await Future<void>.delayed(Duration(milliseconds: delayMs));
  return 'Hello, $name!';
}

/// Completes when the given promise resolves, doubling its value.
Future<int> doubleEventually(Future<int> value) async => (await value) * 2;

/// Adds [days] days to [start].
DateTime addDays(DateTime start, int days) => start.add(Duration(days: days));

/// Length of [text], or null when [text] is null.
int? maybeLength(String? text) => text?.length;

/// Pads [text] to [width] using named options.
String pad(String text, {required int width, String fill = '.'}) =>
    text.padLeft(width, fill);

/// Repeats [text]; [times] is optional positional with a default.
String repeat(String text, [int times = 2]) => text * times;

/// A tagged note with creation time and free-form metadata.
class Note {
  Note(this.title, {required this.createdAt, List<String>? tags})
    : tags = tags ?? [];

  /// Title of the note. Mutable from JS.
  String title;

  /// Creation instant.
  final DateTime createdAt;

  /// Free-form tags.
  final List<String> tags;

  /// Arbitrary JSON-ish metadata.
  Map<String, dynamic> meta = {};

  /// Adds a tag and returns this note (for call chaining across the
  /// boundary).
  Note tag(String value) {
    tags.add(value);
    return this;
  }

  /// Serializes to a JSON-ish map (includes a raw DateTime value).
  Map<String, dynamic> toMap() => {
    'title': title,
    'createdAt': createdAt,
    'tags': tags,
    'meta': meta,
  };

  /// Rebuilds a note from [data] (`fromMap` static, tomorrowtech-style).
  static Note fromMap(Map<String, dynamic> data) => Note(
    data['title'] as String,
    createdAt: data['createdAt'] as DateTime,
    tags: [for (final t in data['tags'] as List) t as String],
  );

  /// Rebuilds many notes at once.
  static List<Note> listFromMaps(Iterable<Map<String, dynamic>> data) =>
      [for (final d in data) Note.fromMap(d)];

  /// A fresh template map (static getter — re-evaluated per access).
  static Map<String, dynamic> get template => {
    'title': 'untitled',
    'createdAt': DateTime.now().toUtc(),
    'tags': <String>[],
  };
}

/// A notebook holding notes (class references in both directions).
class Notebook {
  Notebook(this.name);

  final String name;

  final List<Note> notes = [];

  /// Adds a note (class-typed parameter).
  void add(Note note) => notes.add(note);

  /// Finds a note by title (nullable class-typed return).
  Note? find(String title) {
    for (final note in notes) {
      if (note.title == title) return note;
    }
    return null;
  }

  /// All notes (list of class references).
  List<Note> all() => List.of(notes);

  /// Loads notes asynchronously (Future of class list).
  Future<List<Note>> load() async => all();
}

/// An abstract contract with Stream members: exported as a TYPE-ONLY
/// TypeScript interface (AsyncIterable), never marshalled at runtime.
abstract class NoteRepository {
  Future<Note?> getByTitle(String title);
  Stream<List<Note>> watchAll();
  Future<void> save({required Note note, required bool overwrite});
}
