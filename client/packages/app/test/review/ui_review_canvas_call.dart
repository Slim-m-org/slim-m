// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call, the people and the profiles every canvas review board is seeded with.
library;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart'
    show BatchProfilesController;
import 'package:slimm_app/src/features/voice/providers/voice_state.dart';
import 'package:slimm_rtc/rtc.dart';

/// Nick on the call with Ada speaking and Bo muted; Cy has a cursor but is not on it.
final reviewCall = VoiceState(
  channelId: 'c1',
  state: VoiceSessionState.connected,
  connectedAt: DateTime.now().subtract(
    const Duration(minutes: 12, seconds: 41),
  ),
  participants: const [
    VoiceParticipant(
      identity: 'me',
      name: 'Nick',
      isSpeaking: false,
      isMuted: false,
      isLocal: true,
      isScreenSharing: false,
    ),
    VoiceParticipant(
      identity: 'user-ada',
      name: 'Ada',
      isSpeaking: true,
      isMuted: false,
      isLocal: false,
      isScreenSharing: false,
    ),
    VoiceParticipant(
      identity: 'user-bo',
      name: 'Bo',
      isSpeaking: false,
      isMuted: true,
      isLocal: false,
      isScreenSharing: false,
    ),
  ],
);

const reviewProfiles = [
  api.UserProfile(
    id: 'me',
    username: 'nick',
    displayName: 'Nick',
    createdAt: 0,
  ),
  api.UserProfile(
    id: 'user-ada',
    username: 'ada',
    displayName: 'Ada Lovelace',
    createdAt: 0,
  ),
  api.UserProfile(
    id: 'user-bo',
    username: 'bo',
    displayName: 'Bo Peep',
    createdAt: 0,
  ),
];

/// A profile cache that already holds the review people, so names and avatars resolve without a fetch.
class SeededProfiles extends BatchProfilesController {
  SeededProfiles(super.ref) {
    state = {for (final p in reviewProfiles) p.id: p};
  }
}

/// [reviewCall] with Nick's and Ada's cameras on, so each has a tile on the board.
final reviewCallCameras = reviewCall.copyWith(
  participants: [
    for (final p in reviewCall.participants)
      if (p.identity == 'user-bo') p else p.copyWith(isCameraOn: true),
  ],
);
