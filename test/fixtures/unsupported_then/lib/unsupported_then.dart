/// Fixture: a method named `then` would make wrapper handles JS thenables.
class Job {
  Job(this.id);
  final int id;
  int then(int next) => id + next;
}
