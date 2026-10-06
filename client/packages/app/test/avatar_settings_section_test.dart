// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the settings profile card: the camera badge is a real,
/// touch-sized affordance, the name and `@handle` render with their own
/// rename affordance, "Remove" only offers itself when there is something to
/// remove, and removing it round-trips through the real endpoint and clears
/// the preview once `Me` is refetched.
///
/// The camera badge's own two-source picker sheet has its own file,
/// `avatar_settings_section_picker_test.dart`, split out to stay under the
/// 300-line review budget.
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
import 'package:slimm_app/src/widgets/avatar_settings_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'composer_harness.dart' show usePicker;

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _cameraLabel = 'Change profile picture';

Map<String, dynamic> _meJson(int? avatarUpdatedAt) => {
  'id': 'self',
  'username': 'self',
  'display_name': 'Self',
  'created_at': 0,
  'permissions': 0,
  if (avatarUpdatedAt != null) 'avatar_updated_at': avatarUpdatedAt,
};

Widget _harness(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const Scaffold(body: AvatarSettingsSection()),
  ),
);

void main() {
  testWidgets('no avatar set shows the camera badge and no Remove action', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path == '/me') {
                return http.Response(
                  jsonEncode(_meJson(null)),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response('', 404);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel(_cameraLabel), findsOneWidget);
    expect(find.text('Remove photo'), findsNothing);
  });

  /// The name and handle used to sit above the settings nav as their own
  /// unlabelled block, outside every named section; they are part of this
  /// card now. See the file's own doc comment.
  testWidgets('shows the display name with its own rename affordance, and the '
      '@handle beneath it', (tester) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path == '/me') {
                return http.Response(
                  jsonEncode(_meJson(null)),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response('', 404);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();

    expect(find.text('Self'), findsOneWidget);
    expect(find.text('@self'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit display name'));
    await tester.pumpAndSettle();

    expect(find.text('Edit display name'), findsOneWidget);
  });

  testWidgets('the camera badge meets the 44pt touch-target minimum', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path == '/me') {
                return http.Response(
                  jsonEncode(_meJson(null)),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response('', 404);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.bySemanticsLabel(_cameraLabel));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets(
    'an existing avatar offers Remove, and removing it clears the preview',
    (tester) async {
      int? avatarUpdatedAt = 555;
      final requests = <String>[];
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                requests.add('${request.method} ${request.url.path}');
                if (request.url.path == '/me') {
                  return http.Response(
                    jsonEncode(_meJson(avatarUpdatedAt)),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                if (request.method == 'DELETE' &&
                    request.url.path == '/me/avatar') {
                  avatarUpdatedAt = null;
                  return http.Response('', 204);
                }
                return http.Response('', 404);
              }),
            );
            ref.onDispose(api.close);
            return api;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(container));
      await tester.pumpAndSettle();

      expect(find.text('Remove photo'), findsNothing);
      await tester.tap(find.bySemanticsLabel(_cameraLabel));
      await tester.pumpAndSettle();
      expect(find.text('Remove photo'), findsOneWidget);

      await tester.tap(find.text('Remove photo'));
      await tester.pumpAndSettle();

      expect(requests, contains('DELETE /me/avatar'));
      expect(find.text('Remove photo'), findsNothing);
    },
  );

  /// This section used to catch its own `ApiException` and show it with a
  /// `SnackBar`; see `check-error-surface.py` for the gate that now catches
  /// that shape reappearing here or anywhere else in the app package.
  testWidgets(
    'a refused removal shows a safe sentence inline, not a SnackBar',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                if (request.url.path == '/me') {
                  return http.Response(
                    jsonEncode(_meJson(555)),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                if (request.method == 'DELETE' &&
                    request.url.path == '/me/avatar') {
                  return http.Response(
                    jsonEncode({'error': 'server unavailable'}),
                    500,
                    headers: {'content-type': 'application/json'},
                  );
                }
                return http.Response('', 404);
              }),
            );
            ref.onDispose(api.close);
            return api;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(container));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel(_cameraLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove photo'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AppErrorState), findsOneWidget);
    },
  );

  /// The badge's own file-picker-open failure used to show a `SnackBar`, the
  /// same shape the removal failure above was already fixed away from; see
  /// `check-error-surface.py`'s doc comment for why a raw catch showing one
  /// is the gate's whole target, and `run_guarded.dart`'s `setActionError`
  /// for the seam this needed since a picker throwing carries no
  /// `ApiException` for `guard` to catch.
  testWidgets('a picker that throws is refused inline, not with a SnackBar', (
    tester,
  ) async {
    // Phone width: the inline band takes space a SnackBar never claimed.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    usePicker(null, failure: PlatformException(code: 'no_portal'));

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path == '/me') {
                return http.Response(
                  jsonEncode(_meJson(null)),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response('', 404);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel(_cameraLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(
      find.textContaining('Could not open the file picker'),
      findsOneWidget,
    );
  });
}
