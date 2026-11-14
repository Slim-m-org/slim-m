// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'client.dart';
import 'client_transport.dart';
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
  Future<SoundClip> uploadSoundClip(
    List<int> bytes, {
    required String name,
  }) async {
    final json = await send(
      'POST',
      '/soundboard',
      bytes: bytes,
      query: {'name': name},
    );
    return SoundClip.fromJson(json as Map<String, dynamic>);
  }

  /// Renames a clip. Requires MANAGE_SERVER.
  Future<SoundClip> renameSoundClip(String clipId,
      {required String name}) async {
    final json = await send(
      'PATCH',
      '/soundboard/$clipId',
      body: {'name': name},
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
