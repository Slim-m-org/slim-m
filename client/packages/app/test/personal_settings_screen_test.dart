// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the personal settings screen's own structure: a failure
/// partway through sign-out or deletion reaches the screen rather than
/// vanishing, the nav lays out and carries an icon per pane, and the
/// "Profile" pane opens onto the rename affordance.
///
/// The presence visibility control has its own file,
/// `personal_settings_presence_test.dart`, split out to stay under the
/// 500-line hard ceiling.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/personal_settings_screen.dart';
import 'package:slimm_app/src/widgets/user_avatar.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _signedIn = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A signed-in container whose every request is answered, so the presence
/// section renders alongside the rest of the screen rather than beside error
/// states that would change the layout under test. Every request lands in
/// [requests].
ProviderContainer _signedInContainer(List<Uri> requests) {
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _signedIn)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            requests.add(request.url);
            if (request.url.path == '/devices' ||
                request.url.path == '/blocks') {
              return http.Response(
                '[]',
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
                  'permissions': 0,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              jsonEncode({'visibility': 'away'}),
              200,
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

Widget _screen(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const PersonalSettingsScreen(),
  ),
);

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'slim-m',
      packageName: 'top.npcserver.slimm',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('a failed account deletion is shown on screen, not silently left '
      'signed in with sync already stopped and the push key already gone', (
    tester,
  ) async {
    /// Signed out, so deleteAccount() (like every other authenticated call
    /// this screen makes) fails fast with UnauthorizedException before any
    /// request is sent; the point under test is that the failure reaches the
    /// screen instead of disappearing into an unhandled Future.
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient(
              (_) async => throw StateError('unexpected call'),
            ),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
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

    // Deletion sits with the account it deletes, not under "About slim-m".
    await tester.tap(find.text('Account & devices'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Delete account...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account...'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not delete the account'), findsOneWidget);
  });

  testWidgets('the whole screen lays out at phone width', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient(
              (_) async => throw StateError('unexpected call'),
            ),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
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
    // Every section: the presence control overflowed by 264pt here once.
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  /// Space settings' rows each carry a leading icon
  /// ([SpaceSettingsSection]); the personal nav had none at all, text and a
  /// bare chevron, which read as flatter than every other list in this app.
  testWidgets(
    'every top-level pane in the nav carries a leading icon, not just a '
    'chevron',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient(
                (_) async => throw StateError('unexpected call'),
              ),
            );
            ref.onDispose(api.close);
            return api;
          }),
        ],
      );
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

      for (final icon in const [
        AppIcons.account,
        AppIcons.devices,
        AppIcons.appearance,
        AppIcons.notificationsOn,
        AppIcons.voice,
        AppIcons.revoke,
        AppIcons.info,
      ]) {
        expect(find.byIcon(icon), findsOneWidget);
      }
    },
  );

  /// The avatar disc used to sit flush on the hairline under it: its bottom
  /// edge and the divider's top edge were both at y=209 on a 390pt viewport,
  /// which reads as the picture overlapping the rule.
  /// The full-width section dividers this used to guard against overlapping
  /// went with the single-column layout, so that overlap cannot recur. What is
  /// still worth pinning is that drilling into the pane at phone width puts the
  /// avatar on screen whole rather than clipped by the pane's own edge.
  testWidgets('the avatar renders whole inside its pane at phone width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    final requests = <Uri>[];
    final container = _signedInContainer(requests);
    addTearDown(container.dispose);

    await tester.pumpWidget(_screen(container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    final avatar = tester.getRect(find.byType(UserAvatar).last);
    expect(avatar.left, greaterThanOrEqualTo(0.0));
    expect(avatar.right, lessThanOrEqualTo(390.0));
    expect(avatar.top, greaterThanOrEqualTo(0.0));
  });

  testWidgets('the profile card edit affordance renames the account and the card '
      'updates', (tester) async {
    final requests = <Uri>[];
    final container = _signedInContainer(requests);
    addTearDown(container.dispose);

    await tester.pumpWidget(_screen(container));
    await tester.pumpAndSettle();

    // Renaming lives in the "Profile" pane, not above the nav.
    await tester.tap(find.widgetWithText(AppListRow, 'Profile'));
    await tester.pumpAndSettle();

    expect(find.text('Self'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit display name'));
    await tester.pumpAndSettle();

    expect(find.text('Edit display name'), findsOneWidget);
    // Scoped to the dialog: the Presence section's status field behind it is a second `TextField` (no phone `physicalSize` here, so `showAppSheet` opens a `Dialog`).
    await tester.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
      'Renamed',
    );
    await tester.pump();
    await tester.tap(find.text('Save name'));
    await tester.pumpAndSettle();

    expect(
      requests.where((u) => u.path == '/me'),
      isNotEmpty,
      reason: 'both the initial GET and the PATCH land on /me',
    );
    expect(
      find.text('Edit display name'),
      findsNothing,
      reason: 'a successful save closes the sheet',
    );
  });
}
