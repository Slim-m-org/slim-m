// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Small formatting helpers with no state and no dependency on `intl`,
/// matching `formatMessageTime` in `widgets/message_row_identity.dart`.
library;

/// `YYYY-MM-DD HH:mm` or `YYYY-MM-DD h:mm AM/PM`, local time, following
/// [use24Hour] - resolved once per caller from `resolveUse24Hour` in
/// `providers/display_preferences.dart`, since this file has no widget
/// context of its own to read it from. Used wherever a screen shows a Unix
/// millisecond timestamp that is not a message (a report, an invite, a
/// role) and so has no chat-specific "today" shorthand to reach for.
String formatDateTime(int epochMs, {required bool use24Hour}) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final y = dt.year.toString().padLeft(4, '0');
  final mo = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$mo-$d ${formatClock(dt, use24Hour: use24Hour)}';
}

/// `HH:mm` or `h:mm AM/PM` following [use24Hour]. The 12-hour form joins its
/// suffix with a no-break space so a line never wraps inside the time.
String formatClock(DateTime dt, {required bool use24Hour}) {
  final minute = dt.minute.toString().padLeft(2, '0');
  if (use24Hour) return '${dt.hour.toString().padLeft(2, '0')}:$minute';
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final suffix = dt.hour < 12 ? 'AM' : 'PM';
  return '$hour12:$minute\u00A0$suffix';
}

/// The hours/minutes/seconds a [Duration] breaks into, shared by
/// `CallDuration`'s ticking clock and `formatCallDuration`'s fixed recap
/// string (`widgets/call_participant_tiles.dart` and
/// `widgets/call_recap_card.dart`), which show that breakdown differently on
/// purpose - only the arithmetic to get h/m/s out of the same [Duration] was
/// duplicated.
({int hours, int minutes, int seconds}) decomposeDuration(Duration d) =>
    (hours: d.inHours, minutes: d.inMinutes % 60, seconds: d.inSeconds % 60);

/// "just now", "5m ago", "3h ago", "2d ago" for an [elapsed] age, the single
/// threshold table every relative timestamp in the app shares. [seconds] adds
/// a seconds tier after the first thirty, [weeks] replaces days from seven.
String formatRelativeAge(
  Duration elapsed, {
  bool seconds = false,
  bool weeks = false,
}) {
  if (seconds && elapsed.inSeconds >= 30 && elapsed.inMinutes < 1) {
    return '${elapsed.inSeconds}s ago';
  }
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
  if (weeks && elapsed.inDays >= 7) return '${elapsed.inDays ~/ 7}w ago';
  return '${elapsed.inDays}d ago';
}

/// [formatRelativeAge] for a Unix-millisecond timestamp, against [now].
String formatRelativeAgeMs(int epochMs, {DateTime? now, bool weeks = false}) =>
    formatRelativeAge(
      (now ?? DateTime.now()).difference(
        DateTime.fromMillisecondsSinceEpoch(epochMs),
      ),
      weeks: weeks,
    );
