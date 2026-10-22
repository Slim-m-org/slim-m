// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Forms a bot opened for this account and nobody has shown yet; held until the shell's gate shows it and dropped with the session.
/// See docs/decisions/0083-bot-token-reissue-select-menus-and-forms.md.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';

class BotFormRequest {
  const BotFormRequest({
    required this.interactionId,
    required this.channelId,
    required this.form,
    this.botId,
  });

  final String interactionId;
  final String channelId;
  final api.BotForm form;
  final String? botId;
}

class BotFormsController extends StateNotifier<List<BotFormRequest>> {
  BotFormsController(Ref ref) : super(const []) {
    _sub = ref.read(liveEventsProvider).listen((event) {
      if (event case api.InteractionForm(
        :final interactionId,
        :final channelId,
        :final form,
        :final botId,
      )) {
        state = [
          ...state,
          BotFormRequest(
            interactionId: interactionId,
            channelId: channelId,
            form: form,
            botId: botId,
          ),
        ];
      }
    });
  }

  late final StreamSubscription<api.ServerEvent> _sub;

  /// Hands every waiting form to the caller, which shows them.
  List<BotFormRequest> takeAll() {
    final waiting = state;
    state = const [];
    return waiting;
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

final botFormsProvider =
    StateNotifierProvider<BotFormsController, List<BotFormRequest>>(
      (ref) => BotFormsController(ref),
    );
