// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice-room writes the voice and channel widgets make, so none of them talks to REST.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

class VoiceActions {
  const VoiceActions(this._api);

  final SlimmApi _api;

  Future<void> moveVoiceParticipant(
    String channelId,
    String userId,
    String toChannelId,
  ) => _api.moveVoiceParticipant(channelId, userId, toChannelId);

  Future<Channel> updateVoiceRoom({
    required String channelId,
    String? name,
    bool? locked,
    int? userLimit,
  }) => _api.updateVoiceRoom(
    channelId: channelId,
    name: name,
    locked: locked,
    userLimit: userLimit,
  );
}

final voiceActionsProvider = Provider(
  (ref) => VoiceActions(ref.watch(apiProvider)),
);
