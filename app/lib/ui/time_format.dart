const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// "Today", "Yesterday", "Tuesday", or a plain date once it's far enough back
/// that a weekday name alone would be ambiguous.
String dayLabel(DateTime at) {
  final now = DateTime.now();
  final startOfToday = DateTime(now.year, now.month, now.day);
  final startOfThat = DateTime(at.year, at.month, at.day);
  final dayDiff = startOfToday.difference(startOfThat).inDays;

  return switch (dayDiff) {
    0 => 'Today',
    1 => 'Yesterday',
    _ when dayDiff < 7 => _weekdays[at.weekday - 1],
    _ => '${at.month.toString().padLeft(2, '0')}/'
        '${at.day.toString().padLeft(2, '0')}/${at.year}',
  };
}

/// "3:07 PM" — 12-hour clock, the way a person would actually say it.
String timeLabel(DateTime at) {
  final hour12 = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final minute = at.minute.toString().padLeft(2, '0');
  final period = at.hour < 12 ? 'AM' : 'PM';
  return '$hour12:$minute $period';
}

/// "Today, 3:07 PM".
String dayTimeLabel(DateTime at) => '${dayLabel(at)}, ${timeLabel(at)}';
