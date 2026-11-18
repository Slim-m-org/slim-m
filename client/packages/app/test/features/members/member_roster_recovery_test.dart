// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A members pane that failed to load comes back on its own, and switching
/// channels quickly fetches only the first roster and the one it stops on.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _priya = {
  'id': '1',
  'username': 'priya',
  'display_name': 'Priya',
  'created_at': 0,
};

void main() {
  testWidgets('a failed member fetch recovers without pressing Retry', (
    tester,
  ) async {
    var fail = true;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        mockApiOverride((request) async => http.Response('[]', 200)),
        membersProvider.overrideWith((ref) async => const []),
        channelMembersProvider.overrideWith((ref, _) async {
          if (fail) throw const RateLimitedException('slow down');
          return [UserProfile.fromJson(_priya)];
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: AppMemberPane(channelId: 'c1')),
        ),
      ),
    );
    await pumpFrames(tester);
    expect(find.text('Could not load members.'), findsOneWidget);

    fail = false;
    await tester.pump(appLoadRetryDelays.first);
    await pumpFrames(tester);

    expect(find.text('Could not load members.'), findsNothing);
    expect(find.text('Priya'), findsOneWidget);
  });

  test(
    'switching channels quickly fetches the first and where it stops',
    () async {
      final fetched = <String?>[];
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          mockApiOverride((request) async {
            fetched.add(request.url.queryParameters['channel']);
            return http.Response(jsonEncode([_priya]), 200);
          }),
        ],
      );
      addTearDown(container.dispose);

      for (final channel in ['a', 'b', 'c']) {
        final open = container.listen(
          channelMembersProvider(channel),
          (_, _) {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        open.close();
      }
      final last = container.listen(channelMembersProvider('d'), (_, _) {});
      addTearDown(last.close);
      final roster = await container.read(channelMembersProvider('d').future);

      expect(roster.single.displayName, 'Priya');
      expect(fetched, ['a', 'd']);
    },
  );
}
