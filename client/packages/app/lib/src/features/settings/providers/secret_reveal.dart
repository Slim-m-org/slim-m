// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One-time secrets, held outside any widget so they survive the row or
/// screen that asked for them unmounting before the request answers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// A freshly minted webhook and the delivery URL it is posted to.
typedef WebhookReveal = ({api.NewWebhook created, Uri url});

/// The only copy of a freshly issued bot token, until the admin dismisses it.
final botSecretRevealProvider = StateProvider<api.NewBot?>((ref) {
  // Per account, so a secret never outlives the sign-in that created it.
  ref.watch(sessionProvider.select((s) => s.tokens?.userId));
  return null;
});

/// The only copy of a freshly minted or rotated webhook URL, until dismissed.
final webhookSecretRevealProvider = StateProvider<WebhookReveal?>((ref) {
  ref.watch(sessionProvider.select((s) => s.tokens?.userId));
  return null;
});

/// Shows [created]'s delivery URL, resolved against the connected server.
void revealWebhookSecret(ProviderContainer container, api.NewWebhook created) {
  final url = container.read(apiProvider).baseUrl.resolve(created.deliveryPath);
  container.read(webhookSecretRevealProvider.notifier).state = (
    created: created,
    url: url,
  );
}
