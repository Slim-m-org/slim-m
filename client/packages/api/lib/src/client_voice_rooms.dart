// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Temporary voice rooms (decision 0065).
extension SlimmApiVoiceRooms on SlimmApi {
  /// The caller's room from lobby [channelId]: theirs if it exists, a new
  /// one otherwise. Join the returned channel as usual.
  Future<Channel> openVoiceRoom(String channelId) async {
    final json = await _send('POST', '/channels/$channelId/voice/room');
    return Channel.fromJson(json as Map<String, dynamic>);
  }

  /// The owner's settings; anyone with MANAGE_CHANNELS can change them too.
  Future<Channel> updateVoiceRoom({
    required String channelId,
    String? name,
    bool? locked,
    int? userLimit,
  }) async {
    final json = await _send(
      'PATCH',
      '/channels/$channelId/room',
      body: {
        if (name != null) 'name': name,
        if (locked != null) 'locked': locked,
        if (userLimit != null) 'user_limit': userLimit,
      },
    );
    return Channel.fromJson(json as Map<String, dynamic>);
  }
}
