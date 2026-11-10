// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finishing a Discord link in the app, with the handoff code the browser
/// page shows. It arrives as a tapped link, a web redirect or a paste; the
/// server links only for the account that started the link.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import 'linked_accounts.dart';
import 'settings_actions.dart';

/// The host of the `slimm://` link the browser page opens.
const discordLinkHost = 'discord-link';

/// The web client's path for the same hand-back, under its own base path.
const discordLinkWebPath = '/link/discord';

/// The query key both forms carry the code under.
const discordLinkCodeQuery = 'code';

const _maxCodeChars = 64;

/// The code in [raw], which may be the whole link, or a code with dashes,
/// spaces or lower case from being read off the page; null when none is there.
String? parseDiscordLinkCode(String raw) {
  final trimmed = raw.trim();
  final linked = Uri.tryParse(trimmed)?.queryParameters[discordLinkCodeQuery];
  final code = (linked ?? trimmed).toUpperCase().replaceAll(
    RegExp('[^A-Z0-9]'),
    '',
  );
  return code.isEmpty || code.length > _maxCodeChars ? null : code;
}

/// Where finishing a link stands, for the Connections section to show.
sealed class DiscordLinkStatus {
  const DiscordLinkStatus();
}

class DiscordLinkIdle extends DiscordLinkStatus {
  const DiscordLinkIdle();
}

class DiscordLinkFinishing extends DiscordLinkStatus {
  const DiscordLinkFinishing();
}

/// The attempt ended without a link; [message] stays until dismissed.
class DiscordLinkFailed extends DiscordLinkStatus {
  const DiscordLinkFailed(this.message);

  final String message;
}

class DiscordLinkStatusController extends Notifier<DiscordLinkStatus> {
  @override
  DiscordLinkStatus build() => const DiscordLinkIdle();

  void set(DiscordLinkStatus next) => state = next;
}

final discordLinkStatusProvider =
    NotifierProvider<DiscordLinkStatusController, DiscordLinkStatus>(
      DiscordLinkStatusController.new,
    );

const _refused =
    'That code did not work. It may have expired, or belong to another account.';

class DiscordLinkFinisher {
  DiscordLinkFinisher({
    required this.actions,
    required this.status,
    required this.onLinked,
  });

  /// Read per call, since the API client behind it is replaced with the server.
  final SettingsActions Function() actions;
  final DiscordLinkStatusController status;
  final void Function() onLinked;
  String? _lastDelivered;
  bool _closed = false;

  void close() => _closed = true;

  /// Links with [raw], answering the sentence to show when it did not work.
  Future<String?> complete(String raw) async {
    final code = parseDiscordLinkCode(raw);
    if (code == null) return 'Paste the code from the Discord page.';
    try {
      await actions().completeDiscordLink(code);
      if (!_closed) onLinked();
      return null;
    } on api.NotFoundException {
      return _refused;
    } on api.ApiException catch (error, stack) {
      return reportFailureSentence(
        api.LogTag.ui,
        'finish linking Discord',
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
    status.set(const DiscordLinkFinishing());
    final failure = await complete(code);
    if (_closed) return;
    status.set(
      failure == null ? const DiscordLinkIdle() : DiscordLinkFailed(failure),
    );
  }
}

final discordLinkFinisherProvider = Provider<DiscordLinkFinisher>((ref) {
  final finisher = DiscordLinkFinisher(
    actions: () => ref.read(settingsActionsProvider),
    status: ref.read(discordLinkStatusProvider.notifier),
    onLinked: () => ref.invalidate(myLinkedAccountsProvider),
  );
  ref.onDispose(finisher.close);
  return finisher;
});
