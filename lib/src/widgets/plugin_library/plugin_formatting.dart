import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A failed install as a sentence for people. The installer's own messages
/// (already installed, no valid providers, a blocked destination) are kept
/// word for word; only transport failures, which arrive as raw exceptions,
/// are translated.
String describeInstallError(Object error) => switch (error) {
  SocketException() || http.ClientException() =>
    "Couldn't reach the manifest. Check your connection and try again.",
  TimeoutException() => 'The manifest took too long to answer. Try again.',
  TlsException() => "The manifest's server could not be verified securely.",
  _ => error.toString().replaceFirst(RegExp(r'^[A-Za-z]*Exception:\s*'), ''),
};

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
