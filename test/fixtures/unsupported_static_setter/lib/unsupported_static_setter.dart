/// Fixture: static setters cannot cross the boundary.
class Config {
  Config();
  static String _mode = 'dev';
  static set mode(String value) => _mode = value;
  String get mode => _mode;
}
