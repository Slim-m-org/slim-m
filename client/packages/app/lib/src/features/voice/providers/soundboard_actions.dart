// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The soundboard writes the call picker and the Space settings pane make, so
/// no widget talks to REST.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

class SoundboardActions {
  const SoundboardActions(this._api);

  final SlimmApi _api;

  Future<void> play(String channelId, String clipId) =>
      _api.playSoundClip(channelId, clipId);

  Future<SoundClip> upload(
    List<int> bytes, {
    required String name,
    String? emoji,
  }) => _api.uploadSoundClip(bytes, name: name, emoji: emoji);

  /// Saves both together: a null [emoji] clears it.
  Future<SoundClip> edit(
    String clipId, {
    required String name,
    required String? emoji,
  }) => _api.renameSoundClip(
    clipId,
    name: name,
    emoji: emoji,
    clearEmoji: emoji == null,
  );

  Future<void> delete(String clipId) => _api.deleteSoundClip(clipId);
}

final soundboardActionsProvider = Provider<SoundboardActions>(
  (ref) => SoundboardActions(ref.watch(apiProvider)),
);
