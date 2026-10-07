// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot that re-registers its call controls or menu entries reaches an open
/// channel without remounting it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/bot_ui_uses.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

void main() {
  test('a bot_ui.changed event refetches the open channel\'s bot UI', () async {
    var fetches = 0;
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path == '/channels/c1/bot-ui') fetches++;
              return http.Response(
                jsonEncode(<Object>[]),
                200,
                headers: const {'content-type': 'application/json'},
              );
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);
    final held = container.listen(channelBotUiProvider('c1'), (_, _) {});
    addTearDown(held.close);
    await container.read(channelBotUiProvider('c1').future);
    expect(fetches, 1);

    events.add(const api.BotUiChanged(botUserId: 'bot-1'));
    await Future<void>.delayed(Duration.zero);
    await container.read(channelBotUiProvider('c1').future);
    expect(fetches, 2, reason: 'the open channel picks up the new controls');
  });
}
