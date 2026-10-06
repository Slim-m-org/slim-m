// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The presses this client has sent to a bot and not yet seen answered.
///
/// A press is pending until the bot answers it (`interaction.answered`) and
/// fails visibly if the request is refused or nothing comes back in time. It
/// is in memory only: the server keeps a press for a quarter of an hour and
/// nothing here should outlive a reload. See
/// docs/decisions/0039-bot-message-buttons.md.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../api_failure.dart';
import 'pending_interactions.dart';
import 'providers.dart';

/// How long a press waits for the bot before it is shown as failed.
const Duration buttonPressTimeout = Duration(seconds: 5);

enum ButtonPressStatus { pending, failed }

class ButtonPress {
  const ButtonPress({
    required this.id,
    required this.channelId,
    required this.messageId,
    required this.customId,
    required this.status,
    this.failure,
  });

  final String id;
  final String channelId;
  final String messageId;
  final String customId;
  final ButtonPressStatus status;

  /// Plain words for the person, set only when [status] is failed.
  final String? failure;

  bool get pending => status == ButtonPressStatus.pending;
}

String _keyOf(String messageId, String customId) => '$messageId|$customId';

class ButtonPressesController extends PendingInteractions<ButtonPress> {
  ButtonPressesController(this._ref, {Duration timeout = buttonPressTimeout})
    : super(_ref, timeout);

  final Ref _ref;

  @override
  String idOf(ButtonPress value) => value.id;

  @override
  bool isPending(ButtonPress value) => value.pending;

  @override
  ButtonPress failed(ButtonPress current, String failure) => ButtonPress(
    id: current.id,
    channelId: current.channelId,
    messageId: current.messageId,
    customId: current.customId,
    status: ButtonPressStatus.failed,
    failure: failure,
  );

  /// Ignored while the same button on the same message is already pending.
  Future<void> press({
    required String channelId,
    required String messageId,
    required String customId,
  }) => start(
    _keyOf(messageId, customId),
    pending: (id) => ButtonPress(
      id: id,
      channelId: channelId,
      messageId: messageId,
      customId: customId,
      status: ButtonPressStatus.pending,
    ),
    send: (id) => _ref
        .read(apiProvider)
        .pressMessageButton(
          channelId: channelId,
          messageId: messageId,
          id: id,
          customId: customId,
        ),
    describe: _describe,
  );

  String _describe(api.ApiException e) => switch (e) {
    api.NotFoundException() =>
      'That button is no longer available. The bot or its message may be gone.',
    _ => describeApiFailure('press that button', e),
  };

  /// Clears a failure the person has read or wants to retry past.
  void dismiss(String messageId, String customId) =>
      dismissKey(_keyOf(messageId, customId));
}

/// Not `autoDispose`: a press must keep waiting while its channel is off
/// screen for a moment.
final buttonPressesProvider =
    StateNotifierProvider<ButtonPressesController, Map<String, ButtonPress>>(
      (ref) => ButtonPressesController(ref),
    );

/// The press state of one message's buttons, by `custom_id`.
final messageButtonPressesProvider =
    Provider.family<Map<String, ButtonPress>, String>((ref, messageId) {
      final all = ref.watch(buttonPressesProvider);
      return {
        for (final press in all.values)
          if (press.messageId == messageId) press.customId: press,
      };
    });
