// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'client.dart';
import 'client_transport.dart';
import 'models.dart';

/// Stamps on a shared screen (decision 0121): an emoji or a picture placed on
/// someone's share, and the sharer's list of pictures to report. The `voice` tag.
///
/// Offered only when [Version.supportsScreenStamps] and the sharer's live
/// consent says `stamps`.
extension SlimmApiScreenStamps on SlimmApi {
  /// Places a stamp centred at ([x], [y]), 0 to 1 across [targetUserId]'s shared
  /// screen, whose longest side is [size] of the screen's height. Exactly one of
  /// [emoji] (a reaction key) or [attachmentId] is given. [id] is a client-minted
  /// UUIDv7 that makes a retry of a picture stamp a no-op.
  Future<void> placeScreenStamp(
    String channelId, {
    required String id,
    required String targetUserId,
    required double x,
    required double y,
    required double size,
    String? emoji,
    String? attachmentId,
  }) =>
      send(
        'POST',
        '/channels/$channelId/voice/screen-stamps',
        body: {
          'id': id,
          'target_user_id': targetUserId,
          'x': x,
          'y': y,
          'size': size,
          if (emoji != null) 'emoji': emoji,
          if (attachmentId != null) 'attachment_id': attachmentId,
        },
        expectNoContent: true,
      );

  /// Everyone who stamped pictures on the caller's screen in the last day, by
  /// their latest picture: those not yet reported first, then newest first.
  Future<List<ScreenStampSender>> listReceivedScreenStamps() async {
    final json = await send('GET', '/voice/screen-stamps/received');
    final senders = (json as Map<String, dynamic>)['senders'] as List<dynamic>;
    return senders
        .map((e) => ScreenStampSender.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// The pictures [senderId] stamped on the caller's screen in the last day,
  /// newest first.
  Future<List<ReceivedScreenStamp>> listReceivedScreenStampsFrom(
    String senderId,
  ) async {
    final json = await send('GET', '/voice/screen-stamps/received/$senderId');
    final stamps = (json as Map<String, dynamic>)['stamps'] as List<dynamic>;
    return stamps
        .map((e) => ReceivedScreenStamp.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }
}
