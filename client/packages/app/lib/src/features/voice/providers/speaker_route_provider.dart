// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

/// Speaker or earpiece on a phone with no output picker; tests override it.
final speakerRouteProvider = Provider<SpeakerRoute>((ref) => SpeakerRoute());
