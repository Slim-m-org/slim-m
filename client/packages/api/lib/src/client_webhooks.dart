// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'client.dart';
import 'client_transport.dart';

/// One webhook, as the admin surface lists it. Never carries a credential.
class Webhook {
  const Webhook({
    required this.id,
    required this.channelId,
    required this.label,
    required this.createdAt,
    this.lastDeliveryAt,
    this.createdByDisplayName,
  });

  factory Webhook.fromJson(Map<String, dynamic> json) => Webhook(
        id: json['id'] as String,
        channelId: json['channel_id'] as String,
        label: json['label'] as String,
        createdAt: json['created_at'] as int,
        lastDeliveryAt: json['last_delivery_at'] as int?,
        createdByDisplayName: json['created_by_display_name'] as String?,
      );

  final String id;
  final String channelId;
  final String label;
  final int createdAt;

  /// Null if this webhook has never delivered.
  final int? lastDeliveryAt;

  /// Who minted this webhook. Null if that admin's own account has since
  /// been deleted; the webhook itself keeps working either way.
  final String? createdByDisplayName;
}

/// A freshly created webhook, and the only time its delivery path is ever
/// legible.
class NewWebhook {
  const NewWebhook({required this.webhook, required this.deliveryPath});

  factory NewWebhook.fromJson(Map<String, dynamic> json) => NewWebhook(
        webhook: Webhook.fromJson(json['webhook'] as Map<String, dynamic>),
        deliveryPath: json['delivery_path'] as String,
      );

  final Webhook webhook;

  /// `/webhooks/{id}/{token}`, shown once and unrecoverable afterwards: the
  /// server stores only a hash. Not a full URL - join it to the address this
  /// client already talks to the deployment on to show a pasteable one.
  final String deliveryPath;
}

/// Webhooks: minting, listing, renaming, rotating and revoking, the
/// `webhooks` tag. All five need MANAGE_SERVER. See
/// `docs/decisions/0030-incoming-webhooks.md`.
extension SlimmApiWebhooks on SlimmApi {
  /// Webhooks in the deployment, newest first. Carries no credential.
  Future<List<Webhook>> listWebhooks() async {
    final json = await send('GET', '/webhooks');
    return (json as List<dynamic>)
        .map((entry) => Webhook.fromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Mints a webhook on [channelId] and returns it with its delivery path,
  /// shown only this once.
  Future<NewWebhook> createWebhook(String channelId, String label) async {
    final json = await send(
      'POST',
      '/webhooks',
      body: {'channel_id': channelId, 'label': label},
    );
    return NewWebhook.fromJson(json as Map<String, dynamic>);
  }

  /// Renames a webhook's admin-facing label.
  Future<Webhook> renameWebhook(String webhookId, String label) async {
    final json = await send(
      'PATCH',
      '/webhooks/$webhookId',
      body: {'label': label},
    );
    return Webhook.fromJson(json as Map<String, dynamic>);
  }

  /// Replaces a webhook's token, keeping the webhook and its principal. The
  /// old delivery path 404s at once; the new one is in the result, once.
  Future<NewWebhook> rotateWebhook(String webhookId) async {
    final json = await send('POST', '/webhooks/$webhookId/rotate');
    return NewWebhook.fromJson(json as Map<String, dynamic>);
  }

  /// Revokes a webhook. Its delivery path 404s on its very next attempt.
  Future<void> revokeWebhook(String webhookId) =>
      send('POST', '/webhooks/$webhookId/revoke', expectNoContent: true);
}
