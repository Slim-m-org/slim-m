// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A sign-in that gets no answer says what really failed: a browser that
/// blocked a Space known to be one, or an address nothing answers on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/providers/browser_reach.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/features/auth/widgets/server_identity_confirmation.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/mock_app_version.dart';

Finder _input(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

Future<List<Uri>> _signInWithNoAnswer(
  WidgetTester tester, {
  required bool? answersOutsideBrowser,
  bool pinned = true,
}) async {
  final reached = <Uri>[];
  final keyStore = InMemoryKeyStore();
  if (pinned) {
    await keyStore.put(
      identityHandleFor(Uri.parse('https://chat.example')),
      'pinned-key',
    );
  }
  final noAnswer = MockClient(
    (request) async => throw http.ClientException('Failed to fetch'),
  );
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keyStore),
      serverUrlProvider.overrideWith(
        (ref) => Uri.parse('https://chat.example'),
      ),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: noAnswer),
      ),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: ref.watch(serverUrlProvider),
          session: ref.watch(sessionProvider),
          httpClient: noAnswer,
        );
        ref.onDispose(api.close);
        return api;
      }),
      browserReachProbeProvider.overrideWithValue((server) async {
        reached.add(server);
        return answersOutsideBrowser;
      }),
    ],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const SignInScreen(),
      ),
    ),
  );
  await pumpFrames(tester);
  await tester.enterText(_input('Username'), 'ava');
  await tester.enterText(_input('Password'), 'long enough pw');
  await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
  await waitUntil(tester, () => reached.isNotEmpty);
  await pumpFrames(tester);
  return reached;
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('a known Space that answers outside the browser was blocked', (
    tester,
  ) async {
    final reached = await _signInWithNoAnswer(
      tester,
      answersOutsideBrowser: true,
    );

    expect(reached, [Uri.parse('https://chat.example')]);
    expect(find.textContaining('browser blocked the connection'), findsOne);
    expect(find.textContaining('may be restarting'), findsNothing);
  });

  testWidgets(
    'an answer from a never-confirmed address is not called a Space',
    (tester) async {
      await _signInWithNoAnswer(
        tester,
        answersOutsideBrowser: true,
        pinned: false,
      );

      expect(find.textContaining('Could not reach this Space'), findsOne);
      expect(find.textContaining('browser blocked'), findsNothing);
    },
  );

  testWidgets('an address nothing answers on is unreachable', (tester) async {
    await _signInWithNoAnswer(tester, answersOutsideBrowser: false);

    expect(find.textContaining('Could not reach this Space'), findsOne);
    expect(find.textContaining('browser blocked'), findsNothing);
  });

  testWidgets('off the web an unanswered sign-in is unreachable', (
    tester,
  ) async {
    await _signInWithNoAnswer(tester, answersOutsideBrowser: null);

    expect(find.textContaining('Could not reach this Space'), findsOne);
  });
}
