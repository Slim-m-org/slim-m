// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "show message text on your lock screen" toggle `NotificationsSection`
/// carries: iOS-only (see `personal_status_sections.dart`'s own doc comment
/// on `_PushContentPreviewRow` for why), persisted, and wired to trigger a
/// fresh `PUT /push` carrying the new answer rather than leaving the server
/// holding whatever this device last registered with.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_status_sections.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _label = 'Show message text on your lock screen';

ProviderContainer _container({
  http.Client? httpClient,
  SessionStore? session,
  bool withApnsChannel = false,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      if (session != null) sessionProvider.overrideWithValue(session),
      if (withApnsChannel)
        apnsTokenChannelProvider.overrideWithValue(
          ApnsTokenChannel(isIOS: true),
        ),
      if (httpClient != null)
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: httpClient,
          );
          ref.onDispose(api.close);
          return api;
        }),
    ],
  );
  container.read(preferencesProvider);
  return container;
}

Widget _shell(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const Scaffold(
      body: SingleChildScrollView(child: NotificationsSection()),
    ),
  ),
);

/// Runs [body] with [defaultTargetPlatform] overridden to [platform], and
/// always restores it before returning - never in `tearDown`, which runs
/// too late: `TestWidgetsFlutterBinding._verifyInvariants` asserts every
/// debug var is back to null the instant a `testWidgets` body returns,
/// strictly before any `tearDown`/`addTearDown` callback runs.
Future<void> _withPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Disposes [container] inline, not via `addTearDown`: a successful
/// registration starts a real `Timer.periodic` foreground heartbeat
/// (`PushController._startForegroundHeartbeat`), and `_verifyInvariants`
/// asserts none is pending the instant a `testWidgets` body returns,
/// strictly before any `tearDown` callback runs - the same ordering trap
/// [_withPlatform] guards against for a debug var.
void _disposeBeforeReturning(ProviderContainer container) =>
    container.dispose();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('absent on a non-iOS platform', (tester) async {
    await _withPlatform(TargetPlatform.android, () async {
      await tester.pumpWidget(_shell(_container()));
      await tester.pumpAndSettle();

      expect(find.text(_label), findsNothing);
    });
  });

  MockClient server(List<bool> saved, {bool value = true}) => MockClient((
    request,
  ) async {
    if (request.url.path == '/push/preview') {
      if (request.method == 'PUT') {
        saved.add((jsonDecode(request.body) as Map)['include_content'] as bool);
        return http.Response(request.body, 200);
      }
      return http.Response(jsonEncode({'include_content': value}), 200);
    }
    return http.Response('', 204);
  });

  AppToggle toggleIn(WidgetTester tester) => tester.widget<AppToggle>(
    find.byWidgetPredicate((w) => w is AppToggle && w.semanticLabel == _label),
  );

  testWidgets('shows what the account holds on iOS, on when the server says '
      'on', (tester) async {
    await _withPlatform(TargetPlatform.iOS, () async {
      final container = _container(
        session: SessionStore(tokens: _tokens),
        httpClient: server([]),
      );
      await tester.pumpWidget(_shell(container));
      await tester.pumpAndSettle();

      expect(toggleIn(tester).value, isTrue);
      _disposeBeforeReturning(container);
    });
  });

  testWidgets('shows off when the account says off', (tester) async {
    await _withPlatform(TargetPlatform.iOS, () async {
      final container = _container(
        session: SessionStore(tokens: _tokens),
        httpClient: server([], value: false),
      );
      await tester.pumpWidget(_shell(container));
      await tester.pumpAndSettle();

      expect(toggleIn(tester).value, isFalse);
      _disposeBeforeReturning(container);
    });
  });

  testWidgets('cannot be flipped while the server has not answered', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.iOS, () async {
      final answer = Completer<http.Response>();
      final container = _container(
        session: SessionStore(tokens: _tokens),
        httpClient: MockClient((request) => answer.future),
      );
      await tester.pumpWidget(_shell(container));
      await tester.pump();

      expect(toggleIn(tester).onChanged, isNull);
      answer.complete(http.Response('{"include_content":true}', 200));
      await tester.pumpAndSettle();
      expect(toggleIn(tester).onChanged, isNotNull);
      _disposeBeforeReturning(container);
    });
  });

  testWidgets('turning it off saves the explicit choice to the account', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.iOS, () async {
      final saved = <bool>[];
      final container = _container(
        session: SessionStore(tokens: _tokens),
        httpClient: server(saved),
      );
      await tester.pumpWidget(_shell(container));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is AppToggle && w.semanticLabel == _label,
        ),
      );
      await tester.pumpAndSettle();

      expect(saved, [false]);
      expect(toggleIn(tester).value, isFalse);
      _disposeBeforeReturning(container);
    });
  });

  testWidgets('carries its own accessible name, verified against the real '
      'semantics tree rather than assumed from the widget', (tester) async {
    await _withPlatform(TargetPlatform.iOS, () async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_shell(_container()));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel(_label), findsOneWidget);
      handle.dispose();
    });
  });
}
