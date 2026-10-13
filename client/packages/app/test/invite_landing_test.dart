// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The landing card an invite link opens on: what it shows, how it lays out
/// at phone and desktop width, and that Join only happens from it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/onboarding_screen.dart';
import 'package:slimm_app/src/widgets/invite_landing_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

Future<void> _pumpCard(
  WidgetTester tester,
  double width, {
  bool withBanner = true,
  bool withIcon = false,
  String description = 'A small home server.',
  int members = 12,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: InviteLandingCard(
              name: 'Home',
              memberCount: members,
              description: description,
              invitedBy: 'Nia',
              icon: withIcon
                  ? const ColoredBox(color: Colors.deepOrange)
                  : null,
              banner: withBanner
                  ? const ColoredBox(color: Colors.blueGrey)
                  : null,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('the banner is a 3:1 strip and the card fits at $width', (
      tester,
    ) async {
      await _pumpCard(tester, width);
      final card = tester.getRect(find.byType(InviteLandingCard));
      final banner = tester.getRect(find.byType(AspectRatio));
      expect(card.width, lessThanOrEqualTo(width));
      expect(banner.width, card.width);
      expect(banner.height, closeTo(card.width / kInviteBannerAspect, 0.5));
      expect(banner.top, card.top);
      expect(tester.takeException(), isNull);
      expect(find.text('Nia invited you to'), findsOneWidget);
      expect(find.text('12 members'), findsOneWidget);
    });
  }

  for (final width in [390.0, 1280.0]) {
    testWidgets('the icon sits left of the name at its fixed size at $width', (
      tester,
    ) async {
      await _pumpCard(tester, width, withIcon: true);
      final icon = tester.getRect(find.byType(ColoredBox).last);
      final name = tester.getRect(find.text('Home'));
      expect(icon.size, const Size.square(kInviteIconSize));
      expect(name.left, icon.right + AppSpacing.s12);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('with no icon the name keeps the card gutter', (tester) async {
    await _pumpCard(tester, 390);
    final card = tester.getRect(find.byType(InviteLandingCard));
    final name = tester.getRect(find.text('Home'));
    expect(name.left - card.left, AppSpacing.s16);
  });

  testWidgets('with no banner the text starts at the top of the card', (
    tester,
  ) async {
    await _pumpCard(tester, 390, withBanner: false, description: '');
    expect(find.byType(AspectRatio), findsNothing);
    final card = tester.getRect(find.byType(InviteLandingCard));
    final first = tester.getRect(find.text('Nia invited you to'));
    expect(first.top - card.top, AppSpacing.s16);
    expect(find.text('A small home server.'), findsNothing);
  });

  testWidgets('one member reads in the singular', (tester) async {
    await _pumpCard(tester, 390, members: 1);
    expect(find.text('1 member'), findsOneWidget);
  });

  testWidgets('the join sheet shows the landing card and Join comes after it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Uri? chosen;
    String? invite;
    final httpClient = MockClient((request) async {
      if (request.url.path == '/version') {
        return http.Response(
          jsonEncode(const {
            'name': 'slim-m',
            'version': '0.6.0',
            'protocol': 1,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/invites/CODE123/check') {
        return http.Response(
          jsonEncode(const {
            'usable': true,
            'community': {
              'name': 'Home',
              'member_count': 3,
              'invited_by': 'Nia',
              'uses_remaining': null,
              'expires_at': null,
              'description': 'A small home server.',
              'banner_updated_at': 5,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        probeApiProvider.overrideWithValue(
          (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: OnboardingScreen(
            onServerChosen: (server, code) {
              chosen = server;
              invite = code;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('I have an invite'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'https://chat.example',
    );
    await tester.enterText(find.byType(TextField).at(1), 'CODE123');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.byType(InviteLandingCard), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('A small home server.'), findsOneWidget);
    expect(find.text('3 members'), findsOneWidget);
    expect(chosen, isNull, reason: 'nothing is chosen until Join is pressed');
    final image = tester.widget<Image>(find.byType(Image));
    expect(
      (image.image as NetworkImage).url,
      contains('/invites/CODE123/banner'),
    );

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(InviteLandingCard), findsNothing);
    expect(find.text('Redeem an invite'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(chosen, Uri.parse('https://chat.example'));
    expect(invite, 'CODE123');
  });
}
