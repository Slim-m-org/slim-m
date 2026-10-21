// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one [JoinTimings] a call's controller and session share, so a join's
/// stages from the click to the first remote audio land in one debug-log line.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_rtc/rtc.dart';

final joinTimingsProvider = Provider<JoinTimings>(
  (ref) => JoinTimings(
    onFinished: (summary) => api.AppLog.debug(api.LogTag.voice, summary.line),
  ),
);
