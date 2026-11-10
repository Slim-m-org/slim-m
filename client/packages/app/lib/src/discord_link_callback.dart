// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Discord link's hand-back from the browser page: the
/// `slimm://discord-link?code=` link the OS delivers (see `deep_links.dart`),
/// and the web client's `/link/discord?code=` redirect. Both only finish the
/// link for the account that is signed in; the server refuses any other.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/settings/providers/discord_link_finish.dart';
import 'routing/routes.dart';

bool isDiscordLinkDelivery(Uri uri) =>
    uri.scheme == 'slimm' && uri.host == discordLinkHost;

/// Hands the code in a web `/link/discord?code=` URL to the finisher and
/// returns the Profile pane to continue to, or null when [uri] is not one.
///
/// This is where the callback page's "Open in browser" button arrives. The
/// finish runs on a microtask because a redirect can run while the router is
/// still being built.
String? claimWebDiscordLink(Ref ref, Uri uri) {
  if (uri.path != discordLinkWebPath) return null;
  final code = uri.queryParameters[discordLinkCodeQuery];
  if (code == null) return null;
  Future.microtask(
    () => ref.read(discordLinkFinisherProvider).completeDelivered(code),
  );
  return Routes.personalSettingsPane('profile');
}
