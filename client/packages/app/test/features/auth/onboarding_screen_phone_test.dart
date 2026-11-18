// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the onboarding screen's two modals present at phone width.
///
/// The manual server dialog goes through `showAppSheet` and so collapses to a
/// bottom sheet. Redeeming an invite is a focused full-screen page instead,
/// with a close in its app bar and its actions at the foot of the screen.
///
/// The identity-pinning flow lives in onboarding_screen_test.dart, and
/// userinfo stripping in onboarding_screen_userinfo_test.dart.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/geometry.dart';

const _phone = Size(360, 800);

const _version = {'name': 'slim-m', 'version': '0.6.0', 'protocol': 1};

const _usable = {
  'usable': true,
  'community': {
    'name': 'Home',
    'member_count': 3,
    'invited_by': 'Nia',
    'uses_remaining': null,
    'expires_at': null,
  },
};

Finder _input(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

Future<void> _pumpAtPhoneWidth(WidgetTester tester) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final httpClient = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/version') {
      return http.Response(
        jsonEncode(_version),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    if (request.url.path == '/invites/CODE123/check') {
      return http.Response(
        jsonEncode(_usable),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 200);
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
        home: OnboardingScreen(onServerChosen: (server, invite) {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the manual server dialog collapses to a bottom sheet, like every '
    'other modal in the app, rather than staying a fixed-size dialog',
    (tester) async {
      await _pumpAtPhoneWidth(tester);
      await tester.tap(find.text('Connect to a Space'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
    },
  );

  testWidgets('an invite opens as a full-screen page with a close, not a '
      'sheet', (tester) async {
    await _pumpAtPhoneWidth(tester);
    await tester.tap(find.text('I have an invite'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Where are you joining?'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    final proceed = find.widgetWithText(AppButton, 'Continue');
    expectEdgeGap(tester, proceed, GeometryEdge.bottom, AppSpacing.s16);
    expectEdgeGap(tester, proceed, GeometryEdge.left, AppSpacing.s16);
    expectEdgeGap(tester, proceed, GeometryEdge.right, AppSpacing.s16);

    await tester.tap(find.bySemanticsLabel('Close'));
    await pumpFrames(tester, frames: 20);
    expect(find.text('Where are you joining?'), findsOneWidget);
    expect(find.text('Redeem an invite'), findsNothing);
  });

  testWidgets('Escape closes the full-screen invite, as on any other modal', (
    tester,
  ) async {
    await _pumpAtPhoneWidth(tester);
    await tester.tap(find.text('I have an invite'));
    await pumpFrames(tester, frames: 20);
    await tester.tap(_input('Invite code'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFrames(tester, frames: 20);

    expect(find.text('Where are you joining?'), findsOneWidget);
    expect(find.text('Redeem an invite'), findsNothing);
  });

  testWidgets('the landing card fills the page from the top and Join sits at '
      'its foot', (tester) async {
    await _pumpAtPhoneWidth(tester);
    await tester.tap(find.text('I have an invite'));
    await pumpFrames(tester, frames: 20);
    await tester.enterText(_input('Server'), 'https://chat.example');
    await tester.enterText(_input('Invite code'), 'CODE123');
    await tester.tap(find.text('I accept the terms of use for this Space.'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await pumpFrames(tester, frames: 20);

    expect(find.text('Nia invited you to'), findsOneWidget);
    final join = find.widgetWithText(AppButton, 'Join');
    expectEdgeGap(tester, join, GeometryEdge.bottom, AppSpacing.s16);
    final appBarBottom = tester.getRect(find.bySemanticsLabel('Close')).bottom;
    expect(
      tester.getRect(find.text('Nia invited you to')).top,
      lessThan(appBarBottom + AppSpacing.s48),
    );
  });

  testWidgets('a full-screen invite widened past a phone keeps its form at '
      'sheet width, centred', (tester) async {
    await _pumpAtPhoneWidth(tester);
    await tester.tap(find.text('I have an invite'));
    await pumpFrames(tester, frames: 20);

    tester.view.physicalSize = const Size(1400, 900);
    await pumpFrames(tester);

    for (final control in [
      _input('Invite code'),
      find.widgetWithText(AppButton, 'Continue'),
    ]) {
      final rect = tester.getRect(control);
      expect(rect.width, lessThanOrEqualTo(kSheetMaxWidth));
      expect(rect.center.dx, closeTo(700, 1));
    }
  });
}
