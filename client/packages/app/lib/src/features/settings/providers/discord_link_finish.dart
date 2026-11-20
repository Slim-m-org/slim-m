// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finishing a Discord link in the app: its link constants and the finisher
/// built on the shared [LinkFinisher].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'link_finish.dart';
import 'linked_accounts.dart';
import 'settings_actions.dart';

/// The host of the `slimm://` link the browser page opens.
const discordLinkHost = 'discord-link';

/// The web client's path for the same hand-back, under its own base path.
const discordLinkWebPath = '/link/discord';

final discordLinkStatusProvider =
    NotifierProvider<LinkStatusController, LinkStatus>(
      LinkStatusController.new,
    );

final discordLinkFinisherProvider = Provider<LinkFinisher>((ref) {
  final finisher = LinkFinisher(
    service: 'Discord',
    completeLink: (code) =>
        ref.read(settingsActionsProvider).completeDiscordLink(code),
    status: ref.read(discordLinkStatusProvider.notifier),
    onLinked: () => ref.invalidate(myLinkedAccountsProvider),
  );
  ref.onDispose(finisher.close);
  return finisher;
});
