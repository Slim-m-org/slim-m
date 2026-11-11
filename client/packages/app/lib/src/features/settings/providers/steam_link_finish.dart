// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finishing a Steam link in the app with the handoff code the browser page
/// shows (decision 0115). It follows the Discord link's shape: the code
/// arrives as a tapped link, a web redirect or a paste, and the server links
/// only for the account that started it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import 'discord_link_finish.dart';
import 'linked_accounts.dart';
import 'settings_actions.dart';

/// The host of the `slimm://` link the browser page opens.
const steamLinkHost = 'steam-link';

/// The web client's path for the same hand-back, under its own base path.
const steamLinkWebPath = '/link/steam';

/// Where finishing a Steam link stands, for the Connections section.
sealed class SteamLinkStatus {
  const SteamLinkStatus();
}

class SteamLinkIdle extends SteamLinkStatus {
  const SteamLinkIdle();
}

class SteamLinkFinishing extends SteamLinkStatus {
  const SteamLinkFinishing();
}

/// The attempt ended without a link; [message] stays until dismissed.
class SteamLinkFailed extends SteamLinkStatus {
  const SteamLinkFailed(this.message);

  final String message;
}

class SteamLinkStatusController extends Notifier<SteamLinkStatus> {
  @override
  SteamLinkStatus build() => const SteamLinkIdle();

  void set(SteamLinkStatus next) => state = next;
}

final steamLinkStatusProvider =
    NotifierProvider<SteamLinkStatusController, SteamLinkStatus>(
      SteamLinkStatusController.new,
    );

const _refused =
    'That code did not work. It may have expired, or belong to another account.';

class SteamLinkFinisher {
  SteamLinkFinisher({
    required this.actions,
    required this.status,
    required this.onLinked,
  });

  /// Read per call, since the API client behind it is replaced with the server.
  final SettingsActions Function() actions;
  final SteamLinkStatusController status;
  final void Function() onLinked;
  String? _lastDelivered;
  bool _closed = false;

  void close() => _closed = true;

  /// Links with [raw], answering the sentence to show when it did not work.
  Future<String?> complete(String raw) async {
    final code = parseDiscordLinkCode(raw);
    if (code == null) return 'Paste the code from the Steam page.';
    try {
      await actions().completeSteamLink(code);
      if (!_closed) onLinked();
      return null;
    } on api.NotFoundException {
      return _refused;
    } on api.ApiException catch (error, stack) {
      return reportFailureSentence(
        api.LogTag.ui,
        'finish linking Steam',
        error,
        stack,
      );
    }
  }

  /// [complete] for a code that arrived as a link, reporting through [status].
  /// A code already handled is ignored, since a link can be delivered twice.
  Future<void> completeDelivered(String raw) async {
    final code = parseDiscordLinkCode(raw);
    if (code == null || code == _lastDelivered) return;
    _lastDelivered = code;
    status.set(const SteamLinkFinishing());
    final failure = await complete(code);
    if (_closed) return;
    status.set(
      failure == null ? const SteamLinkIdle() : SteamLinkFailed(failure),
    );
  }
}

final steamLinkFinisherProvider = Provider<SteamLinkFinisher>((ref) {
  final finisher = SteamLinkFinisher(
    actions: () => ref.read(settingsActionsProvider),
    status: ref.read(steamLinkStatusProvider.notifier),
    onLinked: () => ref.invalidate(myLinkedAccountsProvider),
  );
  ref.onDispose(finisher.close);
  return finisher;
});
