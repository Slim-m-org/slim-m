// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A refused bulk delete stays above the selection bar as an error state.
///
/// The bar is still on screen, with the selection intact for a retry, so the
/// failure has a place to sit and a SnackBar was the wrong shape for it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_selection.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/screens/channel_composer_area.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _channel = 'c1';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.SlimmApi _refusingApi(api.SessionStore session) => api.SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: session,
  httpClient: MockClient((request) async {
    if (request.url.path == '/me') {
      return http.Response(
        jsonEncode({
          'id': 'self',
          'username': 'self',
          'display_name': 'Self',
          'created_at': 0,
          'permissions': 0,
        }),
        200,
      );
    }
    return http.Response('boom', 500);
  }),
);

void main() {
  testWidgets('a refused bulk delete is an error state, selection intact', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final client = _refusingApi(ref.watch(sessionProvider));
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ChannelComposerArea(
              channelId: _channel,
              controller: controller,
              channelName: 'general',
              onSend: (_) async {},
              replyingTo: null,
              onCancelReply: () {},
            ),
          ),
        ),
      ),
    );
    container.read(messageSelectionProvider(_channel).notifier).start('m1');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(AppButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Delete').last);
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.textContaining('delete the message'), findsOneWidget);
    expect(
      container.read(messageSelectionProvider(_channel)).contains('m1'),
      isTrue,
    );
  });
}
