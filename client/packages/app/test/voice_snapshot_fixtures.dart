// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [VoiceState] fixtures and the two controller shapes the surfaces matrix
/// pins them through, split out of `ui_snapshot_test.dart` to keep that
/// file a list of tables rather than a place state machines live.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it - the
/// same `canvas_assembled_scene.dart` shape.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/call_recap.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart' show FakeSession;

/// A visible stand-in for a live camera or screen-share track: a real
/// deployment has actual pixels to show, and this box only exists to prove
/// the *layout* holds one, so a flat colour and a label are enough.
class VisibleSnapshotSession extends FakeSession {
  VisibleSnapshotSession({super.needsSource});

  @override
  Widget cameraViewFor(String identity) => const ColoredBox(
    color: Color(0xFF2D5F7C),
    child: Center(
      child: Text('camera', style: TextStyle(color: Colors.white)),
    ),
  );

  @override
  Widget screenShareViewFor(String identity) => const ColoredBox(
    color: Color(0xFF39633B),
    child: Center(
      child: Text('screen share', style: TextStyle(color: Colors.white)),
    ),
  );
}

/// Pinned to a fixed [VoiceState] rather than driven through a real join -
/// safe for any state `VoiceScreen` never reaches its own `stage ==
/// 'joining'` branch for (connected, connecting, or busy-elsewhere), since
/// those never call [VoiceController.join] at all.
class SnapshotVoiceController extends VoiceController {
  SnapshotVoiceController(
    super.ref,
    VoiceState fixed, {
    bool needsSource = false,
  }) : super(session: VisibleSnapshotSession(needsSource: needsSource)) {
    state = fixed;
  }
}

/// Answers `VoiceScreen`'s automatic first join with [outcome] instead of a
/// real network round trip.
///
/// This is the only way to reach the rejoin/error family of states:
/// `_VoiceScreenState`'s own `_autoJoinedFor` gate is private, so nothing
/// outside that widget can set it directly, and it is set only inside the
/// very `join` call this class intercepts. A plain [SnapshotVoiceController]
/// pinned to an already-terminal state renders one frame of "Connecting"
/// instead - `stage` is computed from `_autoJoinedFor` before the widget's
/// own post-frame callback ever runs - and never advances, since nothing
/// here would go on to change [VoiceController.state] again.
class AttemptedJoinVoiceController extends VoiceController {
  AttemptedJoinVoiceController(super.ref, this._outcome)
    : super(session: VisibleSnapshotSession());

  final VoiceState _outcome;

  @override
  Future<void> join(String channelId) async {
    state = _outcome;
  }
}

/// A caller with the camera off, a sharer whose camera is also on (the
/// owner's exact report), and a third, camera-only participant to prove the
/// filmstrip actually scrolls rather than merely fitting two tiles.
final connectedCallState = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  connectedAt: DateTime(2026, 8, 6, 12),
  participants: const [
    VoiceParticipant(
      identity: 'user-nick',
      name: 'Nick',
      isLocal: true,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: false,
    ),
    VoiceParticipant(
      identity: 'user-ada',
      name: 'Ada',
      isLocal: false,
      isSpeaking: true,
      isMuted: false,
      isScreenSharing: true,
      isCameraOn: true,
    ),
    VoiceParticipant(
      identity: 'user-bob',
      name: 'Bob',
      isLocal: false,
      isSpeaking: false,
      isMuted: true,
      isScreenSharing: false,
      isCameraOn: true,
    ),
  ],
);

/// Nobody sharing, so `CallStageLayout` takes its plain wrapped-grid branch
/// - the shape `connectedCallState` never exercises, since Ada is always
/// sharing there. A remote camera-on participant proves the plain grid can
/// carry a live camera tile too, not only the filmstrip.
final gridCallState = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  connectedAt: DateTime(2026, 8, 6, 12),
  participants: const [
    VoiceParticipant(
      identity: 'user-nick',
      name: 'Nick',
      isLocal: true,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: false,
    ),
    VoiceParticipant(
      identity: 'user-ada',
      name: 'Ada',
      isLocal: false,
      isSpeaking: true,
      isMuted: false,
      isScreenSharing: false,
      isCameraOn: true,
    ),
    VoiceParticipant(
      identity: 'user-bob',
      name: 'Bob',
      isLocal: false,
      isSpeaking: false,
      isMuted: true,
      isScreenSharing: false,
    ),
  ],
);

/// [gridCallState] with the local device's own camera on: the plain grid's
/// own tile for the caller, plus the switch-camera control that only shows
/// beside a live local camera.
final localCameraCallState = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  connectedAt: DateTime(2026, 8, 6, 12),
  cameraEnabled: true,
  participants: const [
    VoiceParticipant(
      identity: 'user-nick',
      name: 'Nick',
      isLocal: true,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: false,
      isCameraOn: true,
    ),
    VoiceParticipant(
      identity: 'user-ada',
      name: 'Ada',
      isLocal: false,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: false,
    ),
  ],
);

/// [gridCallState] plus a mid-call error, the banner `voice.error` draws
/// above the grid or stage - never exercised by any other fixture here,
/// since a fixed state has no real session failing under it.
final callWithErrorState = gridCallState.copyWith(
  error: 'Lost the connection to Ada. Reconnecting.',
);

/// The local device sharing its own screen with nobody else sharing:
/// `stageSharer` falls back to the local participant, so this is both the
/// local screen-share banner and the stage-with-filmstrip's local-sharer
/// branch, and the controls row's own lit share button.
final localSharingCallState = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  connectedAt: DateTime(2026, 8, 6, 12),
  screenSharing: true,
  participants: const [
    VoiceParticipant(
      identity: 'user-nick',
      name: 'Nick',
      isLocal: true,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: true,
    ),
    VoiceParticipant(
      identity: 'user-ada',
      name: 'Ada',
      isLocal: false,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: false,
    ),
  ],
);

/// iOS mid-way through starting a broadcast: nobody can see a screen yet,
/// so the controls row's share button is pending rather than lit - the
/// distinction `awaitingBroadcast`'s own doc comment says matters.
final shareAwaitingBroadcastState = gridCallState.copyWith(
  awaitingBroadcast: true,
);

/// The local microphone toggled off, mid-call - `gridCallState`'s remote
/// participants are all unaffected, so only the controls row's own icon
/// changes.
final localMicOffState = gridCallState.copyWith(microphoneEnabled: false);

/// A connected call in a channel other than the one being previewed, so
/// `VoiceScreen`'s `_busyElsewhere` reads true and shows `VoiceSwitchPrompt`
/// rather than auto-joining a second call.
const busyElsewhereState = VoiceState(
  channelId: 'c-elsewhere',
  state: VoiceSessionState.connected,
);

/// A left call with nothing worth summarising - the plain "You left this
/// call." text, distinct from a worthwhile [recapCallState] below.
const leftPlainState = VoiceState(channelId: 'c-main');

/// A left call whose [CallRecap] clears [CallRecap.isWorthShowing]: another
/// participant was actually there, and it ran well past the mis-click floor.
final recapCallState = VoiceState(
  channelId: 'c-main',
  recap: CallRecap(
    channelId: 'c-main',
    startedAt: DateTime(2026, 8, 6, 12),
    endedAt: DateTime(2026, 8, 6, 12, 18),
    others: [
      CallParticipantActivity(
        identity: 'user-ada',
        name: 'Ada',
        joinedAt: DateTime(2026, 8, 6, 12, 1),
      ),
    ],
    sharedScreen: false,
    usedCamera: false,
  ),
);

/// A left call spent entirely alone, past the mis-click floor: no other
/// participant, so [CallRecapCard] has only its own duration and activity
/// to report, no "N other people" stat and no roster below it.
final soloRecapCallState = VoiceState(
  channelId: 'c-main',
  recap: CallRecap(
    channelId: 'c-main',
    startedAt: DateTime(2026, 8, 6, 12),
    endedAt: DateTime(2026, 8, 6, 12, 4),
    others: const [],
    sharedScreen: true,
    usedCamera: false,
  ),
);

/// A failure worth a retry: the SFU dropped mid-join, which is transient by
/// its own nature.
const rejoinErrorRetryableState = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.failed,
  error: 'The call disconnected and could not reconnect.',
  retryable: true,
);

/// A failure no retry can fix: the caller lacks the permission, so the
/// screen offers no button at all rather than one guaranteed to fail again.
const rejoinErrorPermanentState = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.failed,
  error: 'You do not have permission to join this channel.',
  retryable: false,
);

/// The state `VoiceScreen` shows while a token round trip is in flight -
/// never reachable through [AttemptedJoinVoiceController], since that class
/// exists to skip the round trip; this is [SnapshotVoiceController]'s own
/// direct pin instead.
const connectingState = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connecting,
);

/// Who a roster answers a preview with, before anybody has joined -
/// [populatedRoster] below is the same shape with people in it.
const emptyRoster = <api.VoiceRosterParticipant>[];

const populatedRoster = <api.VoiceRosterParticipant>[
  api.VoiceRosterParticipant(userId: 'user-ada', displayName: 'Ada Lovelace'),
  api.VoiceRosterParticipant(userId: 'user-bob', displayName: 'Bob'),
];

/// A DM channel the ordinary text/voice/canvas fixture channels never carry,
/// so `dm-call` states have a `kind: 'dm'` route to reach at all.
const dmChannelId = 'c-dm-ada';

/// A connected call inside [dmChannelId]: `DmCallPane` embeds `VoiceScreen`
/// with `isDm: true`, which is what swaps "Voice channel" for "Call" in its
/// copy.
final dmConnectedCallState = VoiceState(
  channelId: dmChannelId,
  state: VoiceSessionState.connected,
  connectedAt: DateTime(2026, 8, 6, 12),
  participants: const [
    VoiceParticipant(
      identity: 'user-nick',
      name: 'Nick',
      isLocal: true,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: false,
    ),
    VoiceParticipant(
      identity: 'user-ada',
      name: 'Ada',
      isLocal: false,
      isSpeaking: true,
      isMuted: false,
      isScreenSharing: false,
    ),
  ],
);
