// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// This device's own IANA time zone name, for setting up the notification
/// schedule (`docs/decisions/0033-notification-schedule.md`) - the server
/// needs a real zone name, never a raw UTC offset, to evaluate the schedule
/// correctly across a daylight-saving transition. See `docs/dependencies.md`
/// for why `flutter_timezone` is the one platform call this needs.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

/// Read once and cached for the session: the device's own zone does not
/// change while the app is running, and a stale read only matters the next
/// time the schedule is saved, which re-reads nothing here anyway - the
/// value is captured at that save, not watched live.
final deviceTimezoneProvider = FutureProvider<String>((ref) async {
  final info = await FlutterTimezone.getLocalTimezone();
  return info.identifier;
});
