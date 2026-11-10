// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// This device's own IANA time zone name, for setting up the notification
/// schedule (`docs/decisions/0033-notification-schedule.md`) - the server
/// needs a real zone name, never a raw UTC offset, to evaluate the schedule
/// correctly across a daylight-saving transition. See `docs/dependencies.md`
/// for why `flutter_timezone` is the one platform call this needs.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

/// Read at each save and not kept: a failed platform call must not stay
/// cached for the session, and the zone is cheap to ask for again.
final deviceTimezoneProvider = FutureProvider.autoDispose<String>((ref) async {
  final info = await FlutterTimezone.getLocalTimezone();
  return info.identifier;
});
