// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finishing a Steam link in the app (decision 0115): its link constants and
/// the finisher built on the shared [LinkFinisher].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'link_finish.dart';
import 'linked_accounts.dart';
import 'settings_actions.dart';

/// The host of the `slimm://` link the browser page opens.
const steamLinkHost = 'steam-link';

/// The web client's path for the same hand-back, under its own base path.
const steamLinkWebPath = '/link/steam';

final steamLinkStatusProvider =
    NotifierProvider<LinkStatusController, LinkStatus>(
      LinkStatusController.new,
    );

final steamLinkFinisherProvider = Provider<LinkFinisher>((ref) {
  final finisher = LinkFinisher(
    service: 'Steam',
    completeLink: (code) =>
        ref.read(settingsActionsProvider).completeSteamLink(code),
    status: ref.read(steamLinkStatusProvider.notifier),
    onLinked: () => ref.invalidate(myLinkedAccountsProvider),
  );
  ref.onDispose(finisher.close);
  return finisher;
});
