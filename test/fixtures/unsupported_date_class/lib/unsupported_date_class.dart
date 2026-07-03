/// Fixture: a class named `Date` shadows the TS type used for DateTime.
class Date {
  Date(this.year);
  final int year;
}

DateTime startOfYear(Date date) => DateTime.utc(date.year);
