/// Fixture: getter/setter with diverging types.
class Box {
  Box();
  int _value = 0;
  int get value => _value;
  set value(String raw) => _value = int.parse(raw);
}
