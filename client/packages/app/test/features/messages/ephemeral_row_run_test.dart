// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Run on a code block in a bot's private answer runs for this viewer alone:
/// the server stores no private answer, so there is no stored message to
/// share the result against.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/ephemeral_row.dart';
import 'package:slimm_app/src/features/modules/providers/code_block_runner.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'alice',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _answer = api.EphemeralMessage(
  id: 'e1',
  channelId: 'c1',
  authorId: 'bot-1',
  authorDisplayName: 'Helper',
  content: '```js\nconsole.log(1)\n```',
  inReplyToId: 'm1',
  createdAt: 1,
);

void main() {
  testWidgets('Run on a private answer does not address a stored message', (
    tester,
  ) async {
    final requested = <String>[];
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        codeBlockRunnerProvider.overrideWith(
          (ref) async => const [
            api.CodeBlockRunner(
              moduleId: 'code-exec',
              command: 'run',
              language: 'javascript',
            ),
          ],
        ),
        mockApiOverride((request) async {
          if (request.method == 'POST') {
            requested.add('${request.method} ${request.url.path}');
          }
          if (!request.url.path.startsWith('/modules/')) {
            return http.Response('', 404);
          }
          return http.Response(
            jsonEncode({'ok': true, 'output': '1'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: EphemeralRow(
                message: _answer,
                knownUsernames: const {},
                knownRoleNames: const {},
                customEmoji: const {},
                onDismiss: () {},
                onReport: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await waitUntil(
      tester,
      () => container.read(codeBlockRunnerProvider).hasValue,
    );

    await tester.tap(find.bySemanticsLabel('Run with code-exec'));
    await waitUntil(tester, () => requested.isNotEmpty);

    expect(requested, ['POST /modules/code-exec/commands/run']);
    expect(find.text('Result'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
