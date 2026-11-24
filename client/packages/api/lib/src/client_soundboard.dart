// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'client.dart';
import 'client_transport.dart';
import 'exceptions.dart';
import 'list_equality.dart';
import 'logging/app_log.dart';
import 'models.dart';

/// The soundboard: the Space's clips, and playing one into a call. The
/// `soundboard` tag.
///
/// Reading is open to every member. Writing takes MANAGE_SERVER, like custom
/// emoji; playing takes USE_SOUNDBOARD and a seat in the call.
extension SlimmApiSoundboard on SlimmApi {
  /// Every clip in the Space, oldest first.
  Future<List<SoundClip>> listSoundClips() async {
    final json = await send('GET', '/soundboard');
    return (json as List<dynamic>)
        .map((e) => SoundClip.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Adds a clip from raw mp3 or wav [bytes] under [name]. Requires
  /// MANAGE_SERVER. The server holds it to 5 seconds and 512 KB.
  ///
  /// [emoji] is one standard emoji, a custom emoji's id or its `:shortcode:`.
  Future<SoundClip> uploadSoundClip(
    List<int> bytes, {
    required String name,
    String? emoji,
  }) async {
    try {
      final json = await send(
        'POST',
        '/soundboard',
        bytes: bytes,
        query: {'name': name, if (emoji != null) 'emoji': emoji},
      );
      return SoundClip.fromJson(json as Map<String, dynamic>);
    } on ConflictException {
      final landed = await _ownClipWithSameAudio(bytes, name);
      if (landed == null) rethrow;
      return landed;
    }
  }

  /// The caller's own clip named [name] holding exactly [bytes]: an earlier
  /// attempt of this same upload whose reply was lost.
  Future<SoundClip?> _ownClipWithSameAudio(List<int> bytes, String name) async {
    try {
      final me = session.tokens?.userId;
      for (final clip in await listSoundClips()) {
        if (clip.uploaderId != me || clip.name != name) continue;
        final stored = await fetchSoundClipAudio(clip.id);
        if (listEquals(stored.bytes, bytes)) return clip;
      }
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'Could not check whether the clip upload already landed',
        error,
        stack,
      );
    }
    return null;
  }

  /// Renames a clip, changes its emoji, or both. Requires MANAGE_SERVER.
  ///
  /// [emoji] takes what [uploadSoundClip] does; [clearEmoji] removes it.
  Future<SoundClip> renameSoundClip(
    String clipId, {
    String? name,
    String? emoji,
    bool clearEmoji = false,
  }) async {
    assert(
      name != null || emoji != null || clearEmoji,
      'a clip PATCH must carry at least one field',
    );
    assert(!(emoji != null && clearEmoji), 'set the emoji or clear it');
    final json = await send(
      'PATCH',
      '/soundboard/$clipId',
      body: {
        if (name != null) 'name': name,
        if (emoji != null || clearEmoji) 'emoji': emoji,
      },
    );
    return SoundClip.fromJson(json as Map<String, dynamic>);
  }

  /// Removes a clip. Requires MANAGE_SERVER. Idempotent.
  Future<void> deleteSoundClip(String clipId) =>
      send('DELETE', '/soundboard/$clipId', expectNoContent: true);

  /// A clip's audio bytes, safe to cache for as long as the id is held.
  Future<FetchedBytes> fetchSoundClipAudio(String clipId) =>
      fetchBytes('/soundboard/$clipId/audio');

  /// Plays [clipId] into the call the caller is in on [channelId]. Everyone in
  /// the call, the caller included, then receives [SoundboardPlayed].
  Future<void> playSoundClip(String channelId, String clipId) => send(
        'POST',
        '/channels/$channelId/voice/soundboard/$clipId/play',
        expectNoContent: true,
      );
}
