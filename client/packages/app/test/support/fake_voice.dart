// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one [VoiceController] test double: pin a state, or script the calls.
library;

import 'package:slimm_app/src/features/voice/providers/call_recap.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'dead_voice_session.dart';

/// Writing `state` is only possible from inside a [VoiceController], so every
/// suite that renders against a known call goes through this class.
///
/// With [recording] false it keeps the real join, leave and toggles and only
/// exposes the state setters. With it true those four are replaced by
/// stubs that append to [calls] and never touch a session.
class FakeVoiceController extends VoiceController {
  FakeVoiceController(
    super.ref, {
    VoiceState? initial,
    VoiceSession? session,
    this.recording = false,
    this.clearsOnLeave = true,
    this.joinOutcome,
    this.callLength,
  }) : super(session: session ?? DeadVoiceSession()) {
    if (initial != null) state = initial;
  }

  final bool recording;

  /// Whether a recorded leave drops the call; a counting test keeps it up.
  final bool clearsOnLeave;

  /// The state a recorded join lands in; connected to the channel when null.
  final VoiceState? joinOutcome;

  /// When set, a recorded leave ends in a recap of a call this long.
  Duration? callLength;

  /// Every recorded call, in order: `mute`, `deafen`, `leave` or `join:<id>`.
  final calls = <String>[];

  List<String> get joins => [
    for (final c in calls)
      if (c.startsWith('join:')) c.substring(5),
  ];

  int get leaves => calls.where((c) => c == 'leave').length;

  /// Moves the call to [next], the way a join or a hang-up would.
  void replace(VoiceState next) => state = next;

  /// [replace] under the name several suites already use.
  void set(VoiceState next) => state = next;

  void update(VoiceState Function(VoiceState) change) => state = change(state);

  void connect({String channelId = 'c1'}) => state = VoiceState(
    state: VoiceSessionState.connected,
    channelId: channelId,
  );

  void hangUp() => state = const VoiceState();

  /// The call dies on its own, as a lost connection would.
  void drop(String channelId) => state = VoiceState(
    state: VoiceSessionState.failed,
    channelId: channelId,
    error: 'Connection lost.',
  );

  @override
  Future<void> join(String channelId) {
    if (!recording) return super.join(channelId);
    calls.add('join:$channelId');
    state =
        joinOutcome ??
        VoiceState(state: VoiceSessionState.connected, channelId: channelId);
    return Future.value();
  }

  @override
  Future<void> leave() {
    if (!recording) return super.leave();
    calls.add('leave');
    final length = callLength;
    final channelId = state.channelId;
    if (length != null && channelId != null) {
      final now = DateTime.now();
      state = VoiceState(
        recap: CallRecap(
          channelId: channelId,
          startedAt: now.subtract(length),
          endedAt: now,
          others: const <CallParticipantActivity>[],
          sharedScreen: false,
          usedCamera: false,
        ),
        justLeftChannelId: channelId,
        justLeftAt: now,
      );
    } else if (clearsOnLeave) {
      state = const VoiceState();
    }
    return Future.value();
  }

  @override
  Future<void> toggleMicrophone() {
    if (!recording) return super.toggleMicrophone();
    calls.add('mute');
    return Future.value();
  }

  @override
  Future<void> toggleDeafen() {
    if (!recording) return super.toggleDeafen();
    calls.add('deafen');
    return Future.value();
  }
}
