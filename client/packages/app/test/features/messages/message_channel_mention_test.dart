// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A `<#channel-id>` token: how it parses, what it renders as, and where a tap
/// on it goes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/modules/providers/code_block_runner.dart';
import 'package:slimm_app/src/features/messages/widgets/message_inline.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

const _id = '0190a3f2-7c1e-7a55-9b0d-3f2a6c1d8e44';

Channel _channel() => const Channel(
  id: _id,
  name: 'ticket-0001',
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

Future<List<String>> _pump(
  WidgetTester tester,
  String content, {
  bool known = true,
  double width = 1200,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final visited = <String>[];
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: MessageBody(content: content, knownUsernames: const {}),
        ),
      ),
      GoRoute(
        path: '/channels/:channelId',
        builder: (_, state) {
          visited.add(state.uri.toString());
          return const Scaffold(body: Text('channel screen'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        codeBlockRunnerProvider.overrideWith((ref) async => const []),
        channelByIdProvider.overrideWith(
          (ref, id) => Stream.value(known && id == _id ? _channel() : null),
        ),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return visited;
}

void main() {
  group('parsing', () {
    test('a channel token becomes one node with its id', () {
      final nodes = parseInline('open <#$_id> now');

      expect(nodes.whereType<InlineChannelMention>().single.channelId, _id);
      expect(nodes.first, isA<InlineText>());
    });

    test('malformed tokens stay plain text', () {
      for (final raw in ['<#>', '<#abc>', '<#$_id', '<@$_id>', '<# $_id>']) {
        expect(
          parseInline(raw).whereType<InlineChannelMention>(),
          isEmpty,
          reason: raw,
        );
      }
    });

    test('a token inside inline code is not a mention', () {
      expect(
        parseInline('`<#$_id>`').whereType<InlineChannelMention>(),
        isEmpty,
      );
    });
  });

  testWidgets('a known channel renders its name and a tap opens it', (
    tester,
  ) async {
    final visited = await _pump(tester, 'Your ticket is open: <#$_id>');

    expect(find.text('#ticket-0001'), findsOneWidget);
    await tester.tap(find.text('#ticket-0001'));
    await tester.pumpAndSettle();

    expect(visited, ['/channels/$_id?chat=1']);
  });

  testWidgets('an unknown channel reads as unknown and does not navigate', (
    tester,
  ) async {
    final visited = await _pump(tester, 'see <#$_id>', known: false);

    expect(find.text('#unknown-channel'), findsOneWidget);
    await tester.tap(find.text('#unknown-channel'));
    await tester.pumpAndSettle();

    expect(visited, isEmpty);
    expect(find.text('channel screen'), findsNothing);
  });

  testWidgets('at phone width a long line wraps without overflowing', (
    tester,
  ) async {
    final visited = await _pump(
      tester,
      'Your ticket is open and staff have been pinged, jump to it here: '
      '<#$_id> and carry on',
      width: 390,
    );

    expect(tester.takeException(), isNull);
    await tester.tap(find.text('#ticket-0001'));
    await tester.pumpAndSettle();
    expect(visited, hasLength(1));
  });
}
