/// Fixture: non-literal default values cannot be inlined into the facade.
const int kWidth = 3;

String pad(String text, {int width = kWidth}) => text.padLeft(width);
