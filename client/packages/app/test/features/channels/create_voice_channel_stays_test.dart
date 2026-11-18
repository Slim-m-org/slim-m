// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Creating a voice channel leaves the person where they were, and the sheet a
/// voice category's "+" opens starts on Voice.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_section_label.dart';
import 'package:slimm_app/src/features/channels/widgets/create_channel_sheet.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'alice',
  accessToken: 'access-alice',
  refreshToken: 'refresh-alice',
  accessExpiresAt: 0,
);

Finder _nameField() => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == 'Channel name',
);

var _creates = 0;

Future<GoRouter> _pump(WidgetTester tester, Widget opener) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final router = GoRouter(
    initialLocation: '/start',
    routes: [
      GoRoute(
        path: '/start',
        builder: (_, __) => Scaffold(body: Center(child: opener)),
      ),
      GoRoute(
        path: Routes.channelPattern,
        builder: (_, __) => const Placeholder(),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => MessageStore(db)),
        mockApiOverride((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          _creates++;
          return http.Response(
            jsonEncode({
              'id': 'new-voice',
              'name': body['name'],
              'kind': body['kind'],
              'created_at': 0,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return router;
}

void main() {
  testWidgets(
    'a new voice channel does not open, so nobody lands in its empty call view',
    (tester) async {
      final router = await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showCreateChannelSheet(context, initialKind: 'text'),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await pumpFrames(tester, frames: 30);
      await tester.tap(find.text('Voice'));
      await tester.enterText(_nameField(), 'hangout');
      await tester.pump();

      final before = _creates;
      await tester.tap(find.text('Create channel'));
      await waitUntil(
        tester,
        () => _creates > before,
        reason: 'the channel was never created',
      );
      await pumpFrames(tester, frames: 30);

      expect(find.text('Create channel'), findsNothing, reason: 'sheet closed');

      expect(router.routerDelegate.currentConfiguration.uri.path, '/start');
    },
  );

  testWidgets('the + of a voice category starts the sheet on Voice', (
    tester,
  ) async {
    await _pump(
      tester,
      AddChannelGlyph(
        categoryId: 'cat-voice',
        categoryName: 'Voice',
        initialKind: 'voice',
        revealed: true,
        onFocusChange: (_) {},
      ),
    );
    await tester.tap(find.bySemanticsLabel('Create a channel in Voice'));
    await pumpFrames(tester, frames: 30);

    expect(
      find.text(
        'People join a live call to talk, share video and their screen.',
      ),
      findsOneWidget,
    );
    // The open sheet watches the store's categories, a drift stream that only lets go once unmounted.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });

  test('a category starts the sheet on Voice only when it is for calls', () {
    Channel channel(String kind) => Channel(
      id: kind,
      name: kind,
      kind: kind,
      createdAt: 0,
      position: 0,
      cursor: 0,
      lastReadSeq: 0,
      mentionedSeq: 0,
      slowModeSeconds: 0,
      joinMuted: false,
      isPersonalSpace: false,
    );
    const voice = ChannelCategoryRow(id: 'v', name: 'Voice', position: 0);
    const lounge = ChannelCategoryRow(id: 'l', name: 'Lounge', position: 1);

    expect(kindToAddIn(lounge, [channel('voice')]), 'voice');
    expect(kindToAddIn(lounge, [channel('voice'), channel('text')]), 'text');
    expect(kindToAddIn(voice, const []), 'voice');
    expect(kindToAddIn(lounge, const []), 'text');
    expect(kindToAddIn(null, [channel('voice')]), 'text');
  });
}
