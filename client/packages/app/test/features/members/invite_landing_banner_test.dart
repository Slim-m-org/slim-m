// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The live landing preview at the top of Customize. It used to be a page
/// handed a card built at the tap, and the banner's download only started
/// inside that build, so the page always kept the placeholder.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/invite_landing_card.dart';
import 'package:slimm_app/src/features/members/widgets/invite_landing_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

// A 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const _json = {'content-type': 'application/json'};

http.Response _bannerReply() => http.Response.bytes(_png, 200);

http.Response _rosterReply(int members) => http.Response(
  jsonEncode([
    for (var i = 0; i < members; i++)
      {
        'id': 'user-$i',
        'username': 'u$i',
        'display_name': 'User $i',
        'created_at': 0,
      },
  ]),
  200,
  headers: _json,
);

class _Server {
  Completer<http.Response> banner = Completer();
  Completer<http.Response> roster = Completer()..complete(_rosterReply(0));

  Future<http.Response> handle(http.Request r) async {
    switch ((r.method, r.url.path)) {
      case ('GET', '/space/settings'):
        return http.Response(
          jsonEncode({
            'name': 'Hearth Home',
            'join_policy': 'invite',
            'totp_policy': 'optional',
            'description': 'A small server.',
            'banner_updated_at': 7,
            'icon_updated_at': null,
          }),
          200,
          headers: _json,
        );
      case ('GET', '/space/banner'):
        return banner.future;
      case ('GET', '/members'):
        return roster.future;
      default:
        return http.Response('{}', 404, headers: _json);
    }
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Server server, {
  bool Function()? until,
}) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        SessionStore(
          tokens: const TokenPair(
            userId: 'user-1',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: InviteLandingSection()),
        ),
      ),
    ),
  );
  await _framesUntil(tester, until ?? () => _card.evaluate().isNotEmpty);
}

final _bannerImage = find.byWidgetPredicate(
  (w) => w is Image && w.image is MemoryImage,
);

final _card = find.byWidgetPredicate((w) => w is InviteLandingCard);

/// A mocked reply resolves on the real clock and the preview only shows it after a frame, so alternate the two.
Future<void> _framesUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Finder _input(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label),
  matching: find.byWidgetPredicate((w) => w is EditableText),
);

void main() {
  testWidgets(
    'a banner that lands after Customize opened shows in the preview',
    (tester) async {
      final server = _Server();
      await _pump(tester, server);
      expect(_card, findsOneWidget);
      expect(_bannerImage, findsNothing);

      server.banner.complete(_bannerReply());
      await _framesUntil(tester, () => _bannerImage.evaluate().isNotEmpty);
      expect(
        find.descendant(of: _card, matching: _bannerImage),
        findsOneWidget,
      );
    },
  );

  testWidgets('a banner that will not load says so, and retry fetches it', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server);
    server.banner.complete(http.Response('{}', 500, headers: _json));
    await _framesUntil(
      tester,
      () => find.text('Could not load the banner.').evaluate().isNotEmpty,
    );

    server.banner = Completer()..complete(http.Response.bytes(_png, 200));
    await tester.tap(find.text('Retry'));
    await _framesUntil(tester, () => _bannerImage.evaluate().isNotEmpty);
    expect(find.text('Could not load the banner.'), findsNothing);
  });

  testWidgets('the preview follows the name and description as typed', (
    tester,
  ) async {
    await _pump(tester, _Server()..banner.complete(_bannerReply()));
    await tester.enterText(_input('Space name'), 'Hearth Hall');
    await tester.enterText(_input('Description'), 'Friends only.');
    await tester.pump();

    expect(
      find.descendant(of: _card, matching: find.text('Hearth Hall')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _card, matching: find.text('Friends only.')),
      findsOneWidget,
    );

    await tester.enterText(_input('Space name'), '');
    await tester.pump();
    expect(
      find.descendant(of: _card, matching: find.text('Hearth Home')),
      findsOneWidget,
      reason: 'an emptied name previews the saved one',
    );
  });

  testWidgets('at phone width the preview sits above the fields and fits', (
    tester,
  ) async {
    await _pump(tester, _Server()..banner.complete(_bannerReply()));
    final card = tester.getRect(_card);
    expect(
      card.bottom,
      lessThanOrEqualTo(tester.getRect(_input('Space name')).top),
    );
    expect(card.left, greaterThanOrEqualTo(0));
    expect(card.right, lessThanOrEqualTo(390));
    expect(find.text('Preview as a visitor'), findsNothing);
  });

  testWidgets('the preview waits for the roster, then counts its members', (
    tester,
  ) async {
    final server = _Server()..banner.complete(_bannerReply());
    server.roster = Completer();
    await _pump(
      tester,
      server,
      until: () => _input('Space name').evaluate().isNotEmpty,
    );
    expect(_card, findsNothing);
    expect(find.text('0 members'), findsNothing);

    server.roster.complete(_rosterReply(3));
    await _framesUntil(tester, () => _card.evaluate().isNotEmpty);
    expect(
      find.descendant(of: _card, matching: find.text('3 members')),
      findsOneWidget,
    );
  });

  testWidgets('a roster that will not load says so, and retry counts it', (
    tester,
  ) async {
    const failed = 'Could not load the member count.';
    final server = _Server()..banner.complete(_bannerReply());
    server.roster = Completer()
      ..complete(http.Response('{}', 500, headers: _json));
    await _pump(
      tester,
      server,
      until: () => find.text(failed).evaluate().isNotEmpty,
    );
    expect(find.text(failed), findsOneWidget);
    expect(_card, findsNothing);

    server.roster = Completer()..complete(_rosterReply(2));
    await tester.tap(find.text('Retry'));
    await _framesUntil(tester, () => _card.evaluate().isNotEmpty);
    expect(
      find.descendant(of: _card, matching: find.text('2 members')),
      findsOneWidget,
    );
    expect(find.text(failed), findsNothing);
  });
}
