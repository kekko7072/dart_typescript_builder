/// Fixture: the superclass of an exported class must be exported too.
class _Base {
  int get zero => 0;
}

class Child extends _Base {
  Child();
}
