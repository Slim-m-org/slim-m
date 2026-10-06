// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot button press and a bot menu use share one pending-interaction state
/// machine, so they must behave the same: the same timeout wording, a failure
/// that clears on dismiss, and a dismiss of nothing that changes nothing.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/bot_ui_uses.dart';
import 'package:slimm_app/src/providers/button_presses.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'u',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 0,
);

const _timeout = Duration(milliseconds: 20);

final _uses = StateNotifierProvider<BotUiUsesController, Map<String, BotUiUse>>(
  (ref) => BotUiUsesController(ref, timeout: _timeout),
);
final _presses =
    StateNotifierProvider<ButtonPressesController, Map<String, ButtonPress>>(
      (ref) => ButtonPressesController(ref, timeout: _timeout),
    );

/// Answers every request with 204 and never sends `interaction.answered`.
ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pastTimeout() =>
    Future<void>.delayed(_timeout + const Duration(milliseconds: 40));

void main() {
  test('both fail an unanswered interaction with the same words', () async {
    final container = _container();
    final uses = container.read(_uses.notifier);
    final presses = container.read(_presses.notifier);
    await uses.useCallControl(channelId: 'c', botId: 'b', entryId: 'e');
    await presses.press(channelId: 'c', messageId: 'm', customId: 'x');
    await _pastTimeout();

    final useFailure = container.read(_uses)[controlUseKey('c', 'b', 'e')];
    final pressFailure = container.read(_presses)['m|x'];
    expect(useFailure?.pending, isFalse);
    expect(pressFailure?.pending, isFalse);
    expect(useFailure?.failure, startsWith('The bot did not answer.'));
    expect(useFailure?.failure, pressFailure?.failure);
  });

  test('a read failure is cleared by dismiss in both', () async {
    final container = _container();
    await container
        .read(_uses.notifier)
        .useCallControl(channelId: 'c', botId: 'b', entryId: 'e');
    await container
        .read(_presses.notifier)
        .press(channelId: 'c', messageId: 'm', customId: 'x');
    await _pastTimeout();

    container.read(_uses.notifier).dismiss(controlUseKey('c', 'b', 'e'));
    container.read(_presses.notifier).dismiss('m', 'x');

    expect(container.read(_uses), isEmpty);
    expect(container.read(_presses), isEmpty);
  });

  test('dismissing something that is not there notifies nobody', () {
    final container = _container();
    var useNotifications = 0;
    var pressNotifications = 0;
    container.listen(_uses, (_, _) => useNotifications++);
    container.listen(_presses, (_, _) => pressNotifications++);

    container.read(_uses.notifier).dismiss('nothing');
    container.read(_presses.notifier).dismiss('nothing', 'here');

    expect(useNotifications, 0);
    expect(pressNotifications, 0);
  });
}
