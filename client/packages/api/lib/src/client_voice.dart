// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Voice: joining a channel's room, evicting a participant, and previewing
/// who is already in one, the `voice` tag.
extension SlimmApiVoice on SlimmApi {
  /// Mints a join token for a channel's voice room.
  ///
  /// Throws [NotConfiguredException] when the deployment has no SFU, which is
  /// a supported way to run text-only rather than a fault, so a caller should
  /// hide voice rather than retry.
  Future<VoiceToken> voiceToken(String channelId) async {
    final json = await _send('POST', '/channels/$channelId/voice/token');
    return VoiceToken.fromJson(json as Map<String, dynamic>);
  }

  /// Evicts a participant from a channel's voice room.
  ///
  /// Idempotent: removing somebody who is not connected succeeds, so a retry
  /// after a timeout is safe. This does not bar them from rejoining - taking
  /// away CONNECT is what does that - it makes the removal take effect now
  /// rather than when their current token lapses.
  Future<void> kickVoiceParticipant(String channelId, String userId) => _send(
        'POST',
        '/channels/$channelId/voice/participants/$userId/kick',
        expectNoContent: true,
      );

  /// Refreshes proof that this client is still on a channel's call.
  ///
  /// Idempotent, and meant to be sent on a plain interval for as long as the
  /// call is connected: a heartbeat that stops arriving is what the server
  /// uses to bound how long a terminated app can leave a ghost participant
  /// behind, rather than waiting on the SFU's own default. Throws
  /// [NotConfiguredException] when the deployment has no SFU.
  Future<void> sendVoiceHeartbeat(String channelId) => _send(
        'POST',
        '/channels/$channelId/voice/heartbeat',
        expectNoContent: true,
      );

  /// Tells the server this client left a channel's call cleanly, so its
  /// heartbeat entry is dropped now rather than left for the server's sweep
  /// to rediscover once it goes stale and call the SFU about a participant
  /// who already disconnected on their own.
  ///
  /// Best-effort by the caller's own convention, same as [sendVoiceHeartbeat]:
  /// if this never lands, the sweep still cleans up in time, just later and
  /// with a wasted RPC on the server's side.
  Future<void> forgetVoiceHeartbeat(String channelId) => _send(
        'DELETE',
        '/channels/$channelId/voice/heartbeat',
        expectNoContent: true,
      );

  /// Who is currently in a channel's voice room, whether or not this client
  /// has joined it.
  ///
  /// A real round trip to the server's SFU, unlike [voiceToken], which is pure
  /// local signing; poll this on an interval rather than on every render.
  ///
  /// Throws [NotConfiguredException] when the deployment has no SFU (hide the
  /// roster rather than retry), and [UnavailableException] when one is
  /// configured but could not be reached just now (unknown, not empty; keep
  /// showing the last roster you had rather than clearing it to nothing).
  Future<List<VoiceRosterParticipant>> voiceRoster(String channelId) async =>
      (await voiceRosterSnapshot(channelId)).participants;

  /// [voiceRoster] with the call's age the same response carries.
  Future<VoiceRoster> voiceRosterSnapshot(String channelId) async {
    final json = await _send('GET', '/channels/$channelId/voice/roster');
    return VoiceRoster.fromJson(json as Map<String, dynamic>);
  }

  /// Rings the other side of a DM channel's call.
  ///
  /// Throws [NotConfiguredException] when the deployment has no SFU, and
  /// [NotFoundException] for anything that is not a DM between this caller
  /// and exactly one other account.
  Future<RingStarted> ringDmCall(String channelId) async {
    final json = await _send('POST', '/channels/$channelId/voice/ring');
    return RingStarted.fromJson(json as Map<String, dynamic>);
  }

  /// The rings still waiting on this account, newest first.
  ///
  /// For a client that connected after the `call.ringing` frame was sent, such
  /// as an app launched by a VoIP push; nothing is claimed by reading.
  Future<List<OutstandingDmCallRing>> listIncomingDmCallRings() async {
    final json = await _send('GET', '/voice/rings/incoming');
    return ((json as Map<String, dynamic>)['rings'] as List<dynamic>)
        .map((r) => OutstandingDmCallRing.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Declines an incoming DM call ring. Idempotent: declining one that
  /// already ended some other way still succeeds.
  Future<void> declineDmCallRing(String channelId) => _send(
        'POST',
        '/channels/$channelId/voice/ring/decline',
        expectNoContent: true,
      );
}
