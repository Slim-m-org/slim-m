// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Discord and Steam links' hand-back from the browser page: the
/// `slimm://discord-link?code=&server=` link the OS delivers (see
/// `deep_links.dart`), and the web client's `/link/discord?code=` redirect.
/// Both only finish the link for the account that is signed in; the server
/// refuses any other, so the link names the server to reach the right one.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/settings/providers/discord_link_finish.dart';
import 'features/settings/providers/link_finish.dart' show linkCodeQuery;
import 'features/settings/providers/steam_link_finish.dart';
import 'link_query.dart';
import 'routing/routes.dart';

enum LinkService { discord, steam }

/// A code the browser page handed back, and the server that issued it when the link names one.
typedef LinkHandBack = ({LinkService service, String code, Uri? server});

bool isDiscordLinkDelivery(Uri uri) =>
    uri.scheme == 'slimm' && uri.host == discordLinkHost;

bool isSteamLinkDelivery(Uri uri) =>
    uri.scheme == 'slimm' && uri.host == steamLinkHost;

/// The hand-back in [uri], in either its `slimm://` or its web form, or null when it is neither.
LinkHandBack? parseLinkHandBack(Uri uri) {
  final service = _serviceOf(uri);
  final query = queryOrNull(uri);
  final code = query?[linkCodeQuery];
  if (service == null || code == null) return null;
  final server = Uri.tryParse(query?['server']?.trim() ?? '');
  final named = server != null && server.hasScheme && server.host.isNotEmpty;
  return (service: service, code: code, server: named ? server : null);
}

LinkService? _serviceOf(Uri uri) {
  if (isDiscordLinkDelivery(uri)) return LinkService.discord;
  if (isSteamLinkDelivery(uri)) return LinkService.steam;
  if (uri.scheme == 'slimm') return null;
  return switch (uri.path) {
    discordLinkWebPath => LinkService.discord,
    steamLinkWebPath => LinkService.steam,
    _ => null,
  };
}

/// A code that arrived while no session could finish it, kept until one can.
class PendingLinkHandBack {
  LinkHandBack? _held;

  void hold(LinkHandBack handBack) => _held = handBack;

  LinkHandBack? take() {
    final held = _held;
    _held = null;
    return held;
  }
}

/// Plain mutable state rather than a notifier: the router's redirect reads it mid-build, where a provider may not be written.
final pendingLinkHandBackProvider = Provider<PendingLinkHandBack>(
  (ref) => PendingLinkHandBack(),
);

/// Hands [handBack] to the finisher of its service; [read] is a container's or a ref's.
Future<void> finishLinkHandBack(
  T Function<T>(ProviderListenable<T>) read,
  LinkHandBack handBack,
) => switch (handBack.service) {
  LinkService.discord => read(
    discordLinkFinisherProvider,
  ).completeDelivered(handBack.code),
  LinkService.steam => read(
    steamLinkFinisherProvider,
  ).completeDelivered(handBack.code),
};

/// The router's hand-back step: finishes a web `/link/<service>?code=` visit or a parked code and
/// returns the Profile pane to continue to; while signed out it parks the code instead.
///
/// The finish runs on a microtask because a redirect can run while the router is still being built.
String? claimLinkHandBack(Ref ref, Uri uri, {required bool signedIn}) {
  final pending = ref.read(pendingLinkHandBackProvider);
  final arrived = uri.scheme == 'slimm' ? null : parseLinkHandBack(uri);
  if (!signedIn) {
    if (arrived != null) pending.hold(arrived);
    return null;
  }
  final handBack = arrived ?? pending.take();
  if (handBack == null) return null;
  Future.microtask(() => finishLinkHandBack(ref.read, handBack));
  return Routes.personalSettingsPane('profile');
}
