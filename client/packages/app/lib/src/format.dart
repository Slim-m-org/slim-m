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

/// `m:ss`, or `h:mm:ss` from an hour up, clamped at zero: a playback position
/// or a clip length, the one form the watch bar and the video controls share.
String formatPlaybackTime(Duration d) {
  final parts = decomposeDuration(d.isNegative ? Duration.zero : d);
  final ss = parts.seconds.toString().padLeft(2, '0');
  if (parts.hours == 0) return '${parts.minutes}:$ss';
  return '${parts.hours}:${parts.minutes.toString().padLeft(2, '0')}:$ss';
}
