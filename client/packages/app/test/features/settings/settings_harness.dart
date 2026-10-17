// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the suites that pump the personal and Space settings
/// screens: the Space screen's permission gating, and the App group's fixed
/// position on the personal screen regardless of who is looking.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. It
/// exists because every one of those suites needs the same signed-in session,
/// the same `/me` permission answer and the same stubbed device and block
/// lists, none of which any of them is actually about.
///
/// **`/space/settings` is answered for real rather than falling through to
/// the catch-all 404, and that is load-bearing.** A 404 pushed
/// `JoinPolicyRow` into its error branch, which used to render its own
/// `AppListRow` labelled "Who can join" with a Retry beside it - so every
/// gating assertion for that row passed against the *error* state's copy of
/// the label rather than against the row the permission actually unlocks.
/// Converting that branch to `AppErrorState` (decision 0013's raw-Material
/// sweep) removed the label and failed two tests that had been green for the
/// wrong reason the whole time.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/features/settings/screens/personal_settings_screen.dart';
import 'package:slimm_app/src/features/settings/screens/space_settings_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

export '../../support/mock_app_version.dart';

/// Every permission bit the client knows how to name, which is what the
/// server sends a real administrator: `evaluate()`'s ADMINISTRATOR bypass is
/// resolved before `/me` answers, so the wire value already has them all.
int get allPermissionBits => Perm.editable.fold(0, (acc, p) => acc | p.$1);

/// A container with `/me` reporting [permissions] and empty device and block
/// lists, wired the way the running app wires them.
///
/// A token pair is seeded because every call either screen makes, including
/// `/me`, goes through the signed session guard first: without one the client
/// refuses fast with UnauthorizedException before the mock handler ever sees
/// the request, which would make every case read as "no permissions".
ProviderContainer _container(int permissions) {
  const tokens = TokenPair(
    userId: 'self',
    accessToken: 'access',
    refreshToken: 'refresh',
    accessExpiresAt: 0,
  );
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path == '/devices' ||
                request.url.path == '/blocks') {
              return http.Response(
                '[]',
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            // Answered for real; see this library's doc for what a 404 hid.
            if (request.url.path == '/space/settings') {
              return http.Response(
                jsonEncode({'join_policy': 'invite'}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path == '/me') {
              return http.Response(
                jsonEncode({
                  'id': 'self',
                  'username': 'self',
                  'display_name': 'Self',
                  'created_at': 0,
                  'permissions': permissions,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              '{}',
              404,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
}

/// [_container] for a suite that mounts the screens on a router itself.
ProviderContainer settingsContainer(int permissions) => _container(permissions);

/// Renders the personal settings screen with `/me` reporting [permissions],
/// scrolled down to the section under test.
///
/// The App group sits below the whole rest of the list (avatar, appearance,
/// presence, notifications, voice, devices, blocked, account), so the default
/// test viewport does not reach it without scrolling first. The drag is
/// deliberately larger than the list's content, matching the
/// account-deletion test's own reasoning: Flutter clamps to
/// `maxScrollExtent` rather than erroring.
Future<ProviderContainer> pumpPersonalSettings(
  WidgetTester tester,
  int permissions, {
  bool scrollToBottom = true,
}) async {
  final container = _container(permissions);
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const PersonalSettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  if (scrollToBottom) {
    // Deliberately larger than the list's content; see this function's doc.
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();
  }

  return container;
}

/// Renders the Space settings screen with `/me` reporting [permissions].
Future<ProviderContainer> pumpSpaceSettings(
  WidgetTester tester,
  int permissions,
) async {
  final container = _container(permissions);
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const SpaceSettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return container;
}

/// A viewport tall enough to hold the whole personal settings list at once,
/// so every group header is built and their positions are comparable without
/// scrolling any of them out of the tree.
void useTallViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 2400);
  addTearDown(tester.view.reset);
}
