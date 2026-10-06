const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Oct 6, 2026" in local time.
String formatPluginDate(DateTime date) {
  final local = date.toLocal();
  return '${_months[local.month - 1]} ${local.day}, ${local.year}';
}

/// "today", "3 days ago", "2 months ago" or a date for anything older.
String relativePluginDate(DateTime date, {DateTime? now}) {
  final days = (now ?? DateTime.now()).difference(date).inDays;
  if (days < 1) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 30) return '$days days ago';
  if (days < 365) {
    final months = days ~/ 30;
    return months == 1 ? '1 month ago' : '$months months ago';
  }
  return formatPluginDate(date);
}
