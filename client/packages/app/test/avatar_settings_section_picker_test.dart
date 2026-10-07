// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The camera badge's two-source picker: both sources are offered, and
/// choosing one routes to the plugin request that source names.
///
/// Split out of `avatar_settings_section_test.dart`, which was already over
/// the 300-line review budget before this file existed; this half is a
/// self-contained group about the picker sheet rather than the profile
/// card's own content.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
  testWidgets('tapping the camera badge opens both sources, still selectable', (
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

    await tester.tap(find.bySemanticsLabel(_cameraLabel));
    await tester.pumpAndSettle();

    expect(find.text('Choose photo'), findsOneWidget);
    expect(find.text('Browse files'), findsOneWidget);
  });

  /// A recording picker, rather than the unimplemented default, so each row
  /// is pinned to the real plugin request its source names: a routing bug (the
  /// wrong source popped, or the sheet's choice never reaching
  /// `attachmentPickerProvider` at all) changes what the plugin is asked for.
  /// Mirrors `attachment_picker_test.dart`'s own proof.
  for (final (label, expectedType) in [
    ('Choose photo', FileType.image),
    ('Browse files', FileType.any),
  ]) {
    testWidgets(
      'choosing $label routes to the plugin request that source names',
      (tester) async {
        final picker = usePicker(null);

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

        await tester.tap(find.text(label));
        await tester.pumpAndSettle();

        expect(picker.calls, 1, reason: 'the picker was never invoked');
        expect(picker.lastType, expectedType);
        expect(requests, isNot(contains('POST /me/avatar')));
      },
    );
  }
}
