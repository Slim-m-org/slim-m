// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail footer's status avatar had no press feedback at all: a
/// [GestureDetector] with an [onTap] and nothing else, unlike every row and
/// button built on [AppListRow]/[AppButton]/[AppIconButton]. It now scales
/// down on finger-down the same way [AppIconButton] does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/presence_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/reduced_motion_harness.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _me = Me(
  id: 'user-1',
  username: 'ada',
  displayName: 'Ada',
  createdAt: 0,
  permissions: -1,
);

http.Client _emptyApi() => MockClient((_) async => http.Response('[]', 200));

Future<void> _pump(WidgetTester tester, {required bool reduceMotion}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      meProvider.overrideWith((ref) async => _me),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: _emptyApi(),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    reducedMotionApp(
      container: container,
      brightness: Brightness.dark,
      disableAnimations: reduceMotion,
      child: const Center(child: PresenceMenuButton()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the avatar scales down on finger-down and back up on release', (
    tester,
  ) async {
    await _pump(tester, reduceMotion: false);

    final scaleFinder = find.byType(AnimatedScale);
    expect(
      tester.widget<AnimatedScale>(scaleFinder).scale,
      1,
      reason: 'nothing is pressed yet',
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PresenceMenuButton)),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedScale>(scaleFinder).scale,
      AppMotion.pressScale,
      reason: 'finger-down feedback, the same shape AppIconButton uses',
    );

    await gesture.up();
    await tester.pump();
    expect(tester.widget<AnimatedScale>(scaleFinder).scale, 1);
  });

  testWidgets(
    'the scale tween collapses to zero duration under reduce motion',
    (tester) async {
      await _pump(tester, reduceMotion: true);

      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
        Duration.zero,
      );
    },
  );

  testWidgets('the scale tween runs at full speed by default', (tester) async {
    await _pump(tester, reduceMotion: false);

    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
      AppMotion.fast,
    );
  });
}
