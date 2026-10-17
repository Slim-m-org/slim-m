// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who can join, from the client's side: the Space settings row that changes
/// it, and the sign-up notice that explains an invite-only Space instead of
/// just refusing the account.
library;

import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/widgets/join_policy_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets('the row shows the current policy and changes it', (
    tester,
  ) async {
    var stored = 'invite';
    final patched = <String>[];

    final client = MockClient((request) async {
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        stored = body['join_policy'] as String;
        patched.add(stored);
      }
      return http.Response(
        jsonEncode({'join_policy': stored}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(body: JoinPolicyRow()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('People with an invite'), findsOneWidget);

    await tester.tap(find.text('Who can join'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anyone with the address'));
    await tester.pumpAndSettle();

    // The wire value, not the label: the server only accepts these two.
    expect(patched, ['open']);
  });

  /// `join_policy_row.dart:59` used to render `e.message` verbatim in a
  /// `SnackBar`, seventeen lines below a comment stating the opposite rule.
  /// A dropped connection is the case that mattered: `TransportException`'s
  /// message is a method, a path and a Dart exception, none of which belong
  /// in front of a user, and a `SnackBar` floats away rather than staying
  /// on screen until the failure is dealt with.
  testWidgets(
    'a failed save shows a safe sentence inline, not a vanishing SnackBar',
    (tester) async {
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({'join_policy': 'invite'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        throw const SocketException('connection refused');
      });

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final built = api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: client,
            );
            ref.onDispose(built.close);
            return built;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: const Scaffold(body: JoinPolicyRow()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Who can join'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anyone with the address'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(
        find.textContaining('the server could not be reached'),
        findsOneWidget,
      );

      // A state, not a one-shot event: still there several frames later, with nothing having dismissed it.
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(AppErrorState), findsOneWidget);
    },
  );

  // The reported bug: a fixed-width, bordered AppMenu nested inside the sheet.
  testWidgets('on a phone the picker is one surface, spanning the full width', (
    tester,
  ) async {
    const window = Size(360, 800);
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'join_policy': 'invite'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(body: JoinPolicyRow()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Who can join'));
    await tester.pumpAndSettle();

    expect(
      find.byType(AppMenu),
      findsNothing,
      reason:
          'the sheet already draws one surface; AppMenu would nest a '
          'second, bordered card inside it',
    );
    expect(
      tester.getRect(find.byType(BottomSheet)).width,
      window.width,
      reason: 'a phone sheet should be edge to edge, not a floating card',
    );
  });

  testWidgets('the picker is headed by the same words the row is', (
    tester,
  ) async {
    const window = Size(360, 800);
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'join_policy': 'invite'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(body: JoinPolicyRow()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Who can join'));
    await tester.pumpAndSettle();

    // The sheet title is visible chrome, and it named a different setting.
    expect(
      find.textContaining('create an account'),
      findsNothing,
      reason: 'the picker must not rename the setting it is editing',
    );
    expect(find.text('Who can join'), findsWidgets);
  });

  test('an unknown policy from a newer server reads as invite, not open', () {
    expect(api.JoinPolicy.parse('open'), api.JoinPolicy.open);
    expect(api.JoinPolicy.parse('invite'), api.JoinPolicy.invite);
    // The closed one is the only safe default for a value we cannot interpret.
    expect(api.JoinPolicy.parse('approval-queue'), api.JoinPolicy.invite);
  });

  test('a server too old to report the policy says nothing either way', () {
    final version = api.Version.fromJson(const {
      'name': 'slim-m',
      'version': '0.14.1',
      'protocol': 1,
    });
    expect(version.inviteRequired, isNull);
  });

  test('claimed parses when present and is unknown on an older server', () {
    api.Version parse(Map<String, dynamic> extra) => api.Version.fromJson({
      'name': 'slim-m',
      'version': '0.90.0',
      'protocol': 1,
      ...extra,
    });
    expect(parse(const {'claimed': false}).claimed, isFalse);
    expect(parse(const {'claimed': true}).claimed, isTrue);
    expect(parse(const {}).claimed, isNull);
  });
}
