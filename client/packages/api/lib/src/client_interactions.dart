// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// A bot's button press, menu choice and form submit; its own answers come from its process, never this client.
extension SlimmApiInteractions on SlimmApi {
  /// Presses [customId] on [messageId]. [id] is the caller's own UUID, so a
  /// retry after a timeout is the same press rather than a second one.
  Future<void> pressMessageButton({
    required String channelId,
    required String messageId,
    required String id,
    required String customId,
    List<String>? values,
  }) =>
      _send(
        'POST',
        '/channels/$channelId/messages/$messageId/interactions',
        body: {
          'id': id,
          'custom_id': customId,
          if (values != null) 'values': values,
        },
      );

  /// Sends the answers to the form the bot opened for the press
  /// [interactionId]. [id] is the caller's own UUID, so a retry is the same
  /// submission.
  Future<void> submitInteractionForm({
    required String channelId,
    required String interactionId,
    required String id,
    required Map<String, String> fields,
  }) =>
      _send(
        'POST',
        '/channels/$channelId/interactions/$interactionId/submit',
        body: {'id': id, 'fields': fields},
      );
}
