// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a call's screen share remembers, shared by every control that can start one.
///
/// The call screen and the rail's call bar each run their own share flow, so the
/// last source and the one-request-at-a-time guard live here, scoped to the call.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart' show ScreenShareSource;

import 'voice_flags.dart';

class CallShareMemory {
  const CallShareMemory({
    this.lastSourceId,
    this.lastSource,
    this.inFlight = false,
  });

  /// Preselected, never silently reused, the next time the source picker opens.
  final String? lastSourceId;
  final ScreenShareSource? lastSource;

  /// A start is mid-flight, so a second tap from any control is ignored.
  final bool inFlight;

  CallShareMemory copyWith({
    String? lastSourceId,
    ScreenShareSource? lastSource,
    bool? inFlight,
  }) => CallShareMemory(
    lastSourceId: lastSourceId ?? this.lastSourceId,
    lastSource: lastSource ?? this.lastSource,
    inFlight: inFlight ?? this.inFlight,
  );
}

class CallShareMemoryController extends StateNotifier<CallShareMemory> {
  CallShareMemoryController() : super(const CallShareMemory());

  void begin() => state = state.copyWith(inFlight: true);

  void end() => state = state.copyWith(inFlight: false);

  void remember({String? id, ScreenShareSource? source}) =>
      state = state.copyWith(lastSourceId: id, lastSource: source);

  void reset() => state = const CallShareMemory();
}

/// Forgotten whenever the call changes, so one call's source never preselects in the next.
final callShareMemoryProvider =
    StateNotifierProvider<CallShareMemoryController, CallShareMemory>((ref) {
      final controller = CallShareMemoryController();
      ref.listen(
        voiceFlagsProvider.select((v) => v.channelId),
        (_, _) => controller.reset(),
      );
      return controller;
    });
