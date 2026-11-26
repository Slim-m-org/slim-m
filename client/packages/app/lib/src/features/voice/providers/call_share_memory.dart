// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a call's screen share remembers, shared by every control that can start one.
///
/// The call screen and the rail's call bar each run their own share flow, so the
/// last source and the one-request-at-a-time guard live here, scoped to the call.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart' show ScreenShareSource;

class CallShareMemory {
  const CallShareMemory({
    this.channelId,
    this.lastSourceId,
    this.lastSource,
    this.inFlight = false,
  });

  /// The call this record belongs to; a record for another call reads as empty.
  final String? channelId;

  /// Preselected, never silently reused, the next time the source picker opens.
  final String? lastSourceId;
  final ScreenShareSource? lastSource;

  /// A start is mid-flight, so a second tap from any control is ignored.
  final bool inFlight;

  CallShareMemory copyWith({
    String? channelId,
    String? lastSourceId,
    ScreenShareSource? lastSource,
    bool? inFlight,
  }) => CallShareMemory(
    channelId: channelId ?? this.channelId,
    lastSourceId: lastSourceId ?? this.lastSourceId,
    lastSource: lastSource ?? this.lastSource,
    inFlight: inFlight ?? this.inFlight,
  );
}

class CallShareMemoryController extends Notifier<CallShareMemory> {
  @override
  CallShareMemory build() => const CallShareMemory();

  CallShareMemory _for(String? channelId) => state.channelId == channelId
      ? state
      : CallShareMemory(channelId: channelId);

  void begin(String? channelId) =>
      state = _for(channelId).copyWith(inFlight: true);

  void end() => state = state.copyWith(inFlight: false);

  void remember(String? channelId, {String? id, ScreenShareSource? source}) =>
      state = _for(channelId).copyWith(lastSourceId: id, lastSource: source);
}

final callShareMemoryProvider =
    NotifierProvider<CallShareMemoryController, CallShareMemory>(
      CallShareMemoryController.new,
    );
