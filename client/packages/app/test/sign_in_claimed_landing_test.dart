// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// First run opens on the form that fits the deployment's claimed state.
///
/// `/version` says `claimed: false` until the first account registers, and
/// that account becomes the admin, so an unclaimed Space opens on creating
/// one with owner-claim wording. A claimed Space, or a server too old to say,
/// opens on sign-in. A mode chosen by hand is never overridden by the probe.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mock_app_version.dart';

const _phone = Size(390, 844);
const _desktop = Size(1280, 800);

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required Map<String, Object?> version,
  Brightness brightness = Brightness.light,
  Future<void>? answerAfter,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final client = MockClient((request) async {
    await answerAfter;
    return http.Response(
      jsonEncode({
        'name': 'slim-m',
        'version': '0.90.0',
        'protocol': 1,
        'invite_required': true,
        ...version,
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith(
        (ref) => Uri.parse('https://chat.example'),
      ),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: client),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(
          brightness,
          brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
        ),
        home: const SignInScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectInsideViewport(WidgetTester tester, Finder finder, Size size) {
  final rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(size.width));
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThanOrEqualTo(size.height));
}

void main() {
  setUpAll(mockAppVersion);

  for (final (label, size) in [('phone', _phone), ('desktop', _desktop)]) {
    group(label, () {
      testWidgets('an unclaimed Space opens on create-account and says the '
          'first account becomes the administrator', (tester) async {
        await _pump(tester, size: size, version: const {'claimed': false});

        expect(find.text('Create an account'), findsOneWidget);
        expect(find.text('Welcome back'), findsNothing);
        final notice = find.textContaining('first account becomes');
        expect(notice, findsOneWidget);
        expect(find.textContaining('administrator'), findsOneWidget);
        expect(find.textContaining('ask a member'), findsNothing);
        _expectInsideViewport(tester, notice, size);
        final button = find.widgetWithText(AppButton, 'Create account');
        expect(tester.getRect(button).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(button).right, lessThanOrEqualTo(size.width));
        expect(
          tester.getRect(notice).bottom,
          lessThan(tester.getRect(button).top),
          reason: 'the claim wording sits above the action it explains',
        );
      });

      testWidgets('a claimed Space opens on sign-in', (tester) async {
        await _pump(tester, size: size, version: const {'claimed': true});

        expect(find.text('Welcome back'), findsOneWidget);
        expect(find.text('Create an account'), findsNothing);
        expect(find.textContaining('first account'), findsNothing);
        final button = find.widgetWithText(AppButton, 'Sign in');
        expect(tester.getRect(button).right, lessThanOrEqualTo(size.width));
      });

      testWidgets('a server too old to report claimed opens on sign-in', (
        tester,
      ) async {
        await _pump(tester, size: size, version: const {});

        expect(find.text('Welcome back'), findsOneWidget);
      });
    });
  }

  testWidgets('a claimed Space asked to create an account gives the invite '
      'wording without the brand-new hedge', (tester) async {
    await _pump(tester, size: _phone, version: const {'claimed': true});
    await tester.ensureVisible(find.text('Create an account instead'));
    await tester.tap(find.text('Create an account instead'));
    await tester.pumpAndSettle();

    expect(find.textContaining('invite code'), findsOneWidget);
    expect(find.textContaining('brand new'), findsNothing);
    expect(find.textContaining('first account'), findsNothing);
  });

  testWidgets('the dark theme lays the claim notice out the same', (
    tester,
  ) async {
    await _pump(
      tester,
      size: _phone,
      version: const {'claimed': false},
      brightness: Brightness.dark,
    );

    _expectInsideViewport(
      tester,
      find.textContaining('first account becomes'),
      _phone,
    );
  });

  testWidgets('choosing sign-in before the probe answers is not undone by '
      'it answering unclaimed', (tester) async {
    final answer = Completer<void>();
    await _pump(
      tester,
      size: _phone,
      version: const {'claimed': false},
      answerAfter: answer.future,
    );
    expect(find.text('Welcome back'), findsOneWidget);
    await tester.ensureVisible(find.text('Create an account instead'));
    await tester.tap(find.text('Create an account instead'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('I already have an account'));
    await tester.tap(find.text('I already have an account'));
    await tester.pumpAndSettle();

    answer.complete();
    await tester.pumpAndSettle();

    expect(find.text('Welcome back'), findsOneWidget);
  });
}
