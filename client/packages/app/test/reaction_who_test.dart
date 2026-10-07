// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Holding or right-clicking a reaction chip lists who left it; a plain tap
/// still toggles. The sheet and the popover are asserted by where they land,
/// not by the widget merely existing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_extras.dart' show MessageExtras;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/reaction_users_list.dart';
import 'package:slimm_app/src/widgets/reactions_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'message_row_harness.dart' as row;

const _thumb = '\u{1F44D}';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> _profile(String id, String name, {bool bot = false}) => {
  'id': id,
  'username': id,
  'display_name': name,
  'created_at': 0,
  'is_bot': bot,
};

/// Answers the reactor route from [pages] (keyed by the `after` cursor, '' for
/// the first) and `/users` from [profiles], recording every request.
class _Server {
  _Server({this.pages = const {}, this.profiles = const []});

  Map<String, Map<String, Object?>> pages;
  List<Map<String, Object?>> profiles;
  int status = 200;

  /// Answers 500 for the page after this cursor and for no other.
  String? failAfter;
  Completer<void>? hold;
  final requests = <Uri>[];

  Future<http.Response> handle(http.Request request) async {
    requests.add(request.url);
    if (request.url.path == '/users') return _json(profiles);
    await hold?.future;
    if (failAfter != null &&
        request.url.queryParameters['after'] == failAfter) {
      return _json({'error': 'boom'}, 500);
    }
    if (status != 200) return _json({'error': 'boom'}, status);
    final after = request.url.queryParameters['after'] ?? '';
    return _json(pages[after] ?? {'users': <Object>[], 'next_cursor': null});
  }
}

Map<String, Object?> _page(List<String> ids, [String? next]) => {
  'users': [
    for (final id in ids) {'user_id': id},
  ],
  'next_cursor': next,
};

class _Fixture {
  _Fixture(this.server, {this.count = 3, this.inMessageRow = false});

  final _Server server;
  final int count;

  /// Mounts the real [MessageRow], to prove it hands its message id down.
  final bool inMessageRow;
  final tapped = <String>[];
  int rowLongPresses = 0;

  List<api.ReactionSummary> get _reactions => [
    api.ReactionSummary(emoji: _thumb, count: count, reacted: false),
  ];

  Widget _reactionsRow() => ReactionsRow(
    messageId: 'm1',
    reactions: _reactions,
    onReactionTap: (r) => tapped.add(r.emoji),
  );

  Widget _messageRow() => MessageRow(
    message: row.message(id: 'm1'),
    grouped: false,
    showNewDivider: false,
    knownUsernames: const {},
    actions: row.noActions,
    editing: false,
    callbacks: MessageRowCallbacks(
      onRetry: () {},
      onDiscard: () {},
      onPickReaction: (_) {},
      onReactionTap: (r) => tapped.add(r.emoji),
      onVote: (_) {},
      onSubmitEdit: (_) {},
      onCancelEdit: () {},
    ),
    extras: MessageExtras(reactions: _reactions),
  );

  Widget app() => ProviderScope(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(server.handle),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: GestureDetector(
          onLongPress: () => rowLongPresses++,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s24),
              child: inMessageRow ? _messageRow() : _reactionsRow(),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, _Fixture fixture, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(fixture.app());
  await tester.pumpAndSettle();
}

Finder get _chip => find.byType(AppChip);

_Server _ada() => _Server(
  pages: {
    '': _page(['u1', 'u2', 'u3']),
  },
  profiles: [
    _profile('u1', 'Ada'),
    _profile('u2', 'Bob'),
    _profile('u3', 'Helper', bot: true),
  ],
);

void main() {
  test('the hover summary names one, two, three, then counts the rest', () {
    expect(reactionSummaryLine(['Ada'], 1), 'Ada');
    expect(reactionSummaryLine(['Ada', 'Bob'], 2), 'Ada and Bob');
    expect(reactionSummaryLine(['Ada', 'Bob', 'Cy'], 3), 'Ada, Bob and Cy');
    expect(
      reactionSummaryLine(['Ada', 'Bob', 'Cy', 'Di'], 4),
      'Ada, Bob and 2 others',
    );
    expect(
      reactionSummaryLine(['Ada', 'Bob', 'Cy', 'Di', 'Ed'], 5),
      'Ada, Bob and 3 others',
    );
    expect(reactionSummaryLine(['Ada', 'Bob'], 3), 'Ada, Bob and 1 other');
    expect(reactionSummaryLine([], 1), '1 person');
    expect(reactionSummaryLine([], 4), '4 people');
  });

  const phone = Size(390, 844);
  const desktop = Size(1280, 800);

  testWidgets('a long press at phone width opens a bottom sheet of names', (
    tester,
  ) async {
    final fixture = _Fixture(_ada());
    await _pump(tester, fixture, phone);

    await tester.longPress(_chip);
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('3 people'), findsOneWidget);
    for (final name in ['Ada', 'Bob', 'Helper']) {
      expect(find.text(name), findsOneWidget);
    }
    final badge = tester.widget<AppBadge>(find.byType(AppBadge));
    expect(badge.label, 'Bot', reason: 'a bot is badged, once');
    final sheet = tester.getRect(find.byType(BottomSheet));
    expect(sheet.bottom, phone.height, reason: 'sits on the bottom edge');
    expect(sheet.width, phone.width);
    expect(fixture.tapped, isEmpty, reason: 'holding must not toggle');
    expect(
      fixture.rowLongPresses,
      0,
      reason: 'the chip wins the long press over the row behind it',
    );
  });

  testWidgets('a real message row hands its id down to the chip', (
    tester,
  ) async {
    final fixture = _Fixture(_ada(), inMessageRow: true);
    await _pump(tester, fixture, phone);

    await tester.longPress(_chip);
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(
      fixture.server.requests.map((u) => u.path),
      contains(startsWith('/messages/m1/reactions/')),
    );
  });

  testWidgets('a plain tap still toggles and opens nothing', (tester) async {
    final fixture = _Fixture(_ada());
    await _pump(tester, fixture, phone);

    await tester.tap(_chip);
    await tester.pumpAndSettle();

    expect(fixture.tapped, [_thumb]);
    expect(find.byType(BottomSheet), findsNothing);
    expect(fixture.server.requests, isEmpty, reason: 'no lookup on a tap');
  });

  testWidgets('shows a spinner while loading', (tester) async {
    final server = _ada()..hold = Completer<void>();
    final fixture = _Fixture(server);
    await _pump(tester, fixture, phone);

    await tester.longPress(_chip);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Ada'), findsNothing);

    server.hold!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Ada'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('an empty list says so', (tester) async {
    final fixture = _Fixture(_Server(pages: {'': _page([])}));
    await _pump(tester, fixture, phone);

    await tester.longPress(_chip);
    await tester.pumpAndSettle();

    expect(find.text('No one has this reaction now.'), findsOneWidget);
  });

  testWidgets('a failure persists with a retry, never a snackbar', (
    tester,
  ) async {
    final server = _ada()..status = 500;
    final fixture = _Fixture(server);
    await _pump(tester, fixture, phone);

    await tester.longPress(_chip);
    await tester.pumpAndSettle();

    expect(find.text('Could not load who reacted.'), findsOneWidget);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    server.status = 200;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Could not load who reacted.'), findsNothing);
  });

  testWidgets('a failing next page is asked for once, then waits for Retry', (
    tester,
  ) async {
    final server = _Server(
      pages: {
        '': _page(['u1', 'u2'], 'c1'),
      },
      profiles: [_profile('u1', 'Ada'), _profile('u2', 'Bob')],
    )..failAfter = 'c1';
    await _pump(tester, _Fixture(server), phone);

    await tester.longPress(_chip);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final asked = server.requests.where(
      (u) => u.queryParameters['after'] == 'c1',
    );
    expect(asked, hasLength(1), reason: 'one failed attempt, then Retry');
    expect(find.text('Could not load more.'), findsOneWidget);
  });

  testWidgets('Retry after a failed next page loads it', (tester) async {
    final server = _Server(
      pages: {
        '': _page(['u1', 'u2'], 'c1'),
        'c1': _page(['u3']),
      },
      profiles: [
        _profile('u1', 'Ada'),
        _profile('u2', 'Bob'),
        _profile('u3', 'Cy'),
      ],
    )..failAfter = 'c1';
    await _pump(tester, _Fixture(server), phone);
    await tester.longPress(_chip);
    await tester.pumpAndSettle();
    expect(find.text('Cy'), findsNothing);

    server.failAfter = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Cy'), findsOneWidget);
    expect(find.text('Could not load more.'), findsNothing);
  });

  testWidgets('a long list follows its cursor for the next page', (
    tester,
  ) async {
    final server = _Server(
      pages: {
        '': _page(['u1', 'u2'], 'c1'),
        'c1': _page(['u3']),
      },
      profiles: [
        _profile('u1', 'Ada'),
        _profile('u2', 'Bob'),
        _profile('u3', 'Cy'),
      ],
    );
    final fixture = _Fixture(server);
    await _pump(tester, fixture, phone);

    await tester.longPress(_chip);
    await tester.pumpAndSettle();

    final reactorCalls = server.requests
        .where((u) => u.path.startsWith('/messages/m1/reactions/'))
        .toList();
    expect(reactorCalls.map((u) => u.queryParameters['after']), [null, 'c1']);
    expect(find.text('Cy'), findsOneWidget);
  });

  testWidgets('right-click at desktop width opens an anchored popover', (
    tester,
  ) async {
    final fixture = _Fixture(_ada());
    await _pump(tester, fixture, desktop);

    await tester.tap(_chip, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(AppMenu), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    final popover = tester.getRect(find.byType(AppMenu));
    final chip = tester.getRect(_chip);
    expect(popover.width, 280);
    expect(
      popover.overlaps(chip),
      isFalse,
      reason: 'the popover sits beside the chip, not on it',
    );
    expect(popover.right, lessThanOrEqualTo(desktop.width));
    expect(popover.bottom, lessThanOrEqualTo(desktop.height));
    expect(fixture.tapped, isEmpty);
  });

  testWidgets('the context-menu key on a focused chip opens the list', (
    tester,
  ) async {
    final fixture = _Fixture(_ada());
    await _pump(tester, fixture, desktop);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();

    expect(find.byType(AppMenu), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(fixture.tapped, isEmpty, reason: 'opening the list must not toggle');
  });

  testWidgets('hovering a chip summarises the first names', (tester) async {
    final server = _Server(
      pages: {
        '': _page(['u1', 'u2', 'u3', 'u4', 'u5']),
      },
      profiles: [
        _profile('u1', 'Ada'),
        _profile('u2', 'Bob'),
        _profile('u3', 'Cy'),
        _profile('u4', 'Di'),
        _profile('u5', 'Ed'),
      ],
    );
    final fixture = _Fixture(server, count: 5);
    await _pump(tester, fixture, desktop);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_chip));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Ada, Bob and 3 others'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a quick pass over a chip asks the server nothing', (
    tester,
  ) async {
    final fixture = _Fixture(_ada());
    await _pump(tester, fixture, desktop);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_chip));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.moveTo(const Offset(900, 600));
    await tester.pumpAndSettle();

    expect(fixture.server.requests, isEmpty);
  });
}
