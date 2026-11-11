// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Steam row of Connections: linking, unlinking and the "share what I'm
/// playing" switch (decision 0115). The server holds the switch, because it
/// is what lets it ask Steam about this member, so a change is a request and
/// the switch shows the choice at once while the request is in flight.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../external_link.dart';
import '../../../api_failure.dart';
import 'linked_accounts.dart';
import 'settings_actions.dart';

class SteamConnectionState {
  const SteamConnectionState({this.busy = false, this.error, this.sharing});

  final bool busy;

  /// A sentence for the last failure; stays until dismissed.
  final String? error;

  /// The switch as just chosen, until the refetched link says the same.
  final bool? sharing;
}

class SteamConnection extends Notifier<SteamConnectionState> {
  @override
  SteamConnectionState build() => const SteamConnectionState();

  void dismissError() => state = SteamConnectionState(sharing: state.sharing);

  Future<void> link() async {
    state = const SteamConnectionState(busy: true);
    final error = await _guarded(
      whatFailed: 'start linking Steam',
      action: () async {
        try {
          final url = await ref.read(settingsActionsProvider).startSteamLink();
          await openExternalHttpUrl(
            url,
            launcher: ref.read(externalUrlLauncherProvider),
          );
        } on api.NotConfiguredException catch (error, stack) {
          api.AppLog.swallowed(
            api.LogTag.ui,
            'Could not start the Steam link',
            error,
            stack,
          );
          ref.read(steamLinkUnavailableProvider.notifier).state = true;
        }
      },
    );
    state = SteamConnectionState(error: error);
  }

  Future<void> unlink() async {
    state = const SteamConnectionState(busy: true);
    final error = await _guarded(
      whatFailed: 'unlink Steam',
      action: () async {
        await ref.read(settingsActionsProvider).unlinkSteam();
        ref.invalidate(myLinkedAccountsProvider);
      },
    );
    state = SteamConnectionState(error: error);
  }

  Future<void> setSharing(bool enabled) async {
    state = SteamConnectionState(sharing: enabled);
    final error = await _guarded(
      whatFailed: 'change what Steam shares',
      action: () async {
        await ref
            .read(settingsActionsProvider)
            .setSteamSharing(enabled: enabled);
        ref.invalidate(myLinkedAccountsProvider);
        await ref.read(myLinkedAccountsProvider.future);
      },
    );
    state = SteamConnectionState(error: error);
  }
}

final steamConnectionProvider =
    NotifierProvider<SteamConnection, SteamConnectionState>(
      SteamConnection.new,
    );

/// Runs [action], answering null on success or the sentence to show.
Future<String?> _guarded({
  required String whatFailed,
  required Future<void> Function() action,
}) async {
  try {
    await action();
    return null;
  } on api.ApiException catch (error, stack) {
    return reportFailureSentence(api.LogTag.ui, whatFailed, error, stack);
  }
}
