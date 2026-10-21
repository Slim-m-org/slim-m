// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The invite and manual-server dialogs, and the two trust-on-first-use
/// identity screens both entry points can fall into on the way through.
///
/// None of these are a `show*(context, ref)` one-shot open the way
/// `ui_overlay_snapshot_test.dart`'s own `_overlays` map wants: each needs
/// typed input, a submit, and a mocked network answer before the state worth
/// a picture exists at all, so this drives `OnboardingScreen` directly with
/// `tester`, the same shape `onboarding_screen_test.dart` already proved out.
///
/// Same split as every sibling in this family: the overflow assertion runs
/// everywhere, the PNGs are written only under SLIMM_UI_SNAPSHOTS=1. One
/// viewport (desktop) per state, plus one phone-width mismatch warning - the dialogs collapse to a bottom sheet
/// below 600px with identical content, and the identity screens carry no
/// responsive branch at all (see `server_fingerprint_test.dart`).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/api_failure.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

import 'support/mid_flight_capture.dart';
import 'support/onboarding_error_strings.dart';
import 'ui_snapshot_support.dart';

final _errorStrings = OnboardingErrorStrings.load();

const _viewport = Size(1400, 880);

const _identityA = {
  'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  'fingerprint': 'deadbeefcafebabefeedface1337d00d',
  'fingerprint_groups': [
    'dead',
    'beef',
    'cafe',
    'babe',
    'feed',
    'face',
    '1337',
    'd00d',
  ],
  'color_strip': [0, 1, 2, 3],
};

const _identityB = {
  'public_key': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  'fingerprint': 'facefeedf00dd00dfacefeedf00dd00d',
  'fingerprint_groups': [
    'face',
    'feed',
    'f00d',
    'd00d',
    'face',
    'feed',
    'f00d',
    'd00d',
  ],
  'color_strip': [4, 5, 0, 1],
};

/// [versionBody] answers `/version` for every probe this screen makes;
/// [checkBody]/[checkStatus] answer `/invites/{code}/check` for the invite
/// dialog specifically. `throwOnCheck` reproduces an unreachable server:
/// `_perform` maps any thrown exception to `TransportException`, the same
/// path a real dropped connection takes.
Future<ProviderContainer> _pumpOnboarding(
  WidgetTester tester, {
  Map<String, Object?>? versionBody,
  Map<String, Object?>? checkBody,
  int checkStatus = 200,
  bool throwOnCheck = false,
  KeyStore? keyStore,
  Size viewport = _viewport,
}) async {
  final httpClient = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/version') {
      return http.Response(
        jsonEncode(
          versionBody ??
              const {'name': 'slim-m', 'version': '0.6.0', 'protocol': 1},
        ),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    if (request.url.path.endsWith('/check')) {
      if (throwOnCheck) throw Exception('connection refused');
      return http.Response(
        jsonEncode(checkBody ?? const {'usable': false}),
        checkStatus,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 200);
  });

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keyStore ?? InMemoryKeyStore()),
      probeApiProvider.overrideWithValue(
        (baseUrl) => api.SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
      ),
    ],
  );
  addTearDown(container.dispose);

  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: OnboardingScreen(onServerChosen: (server, invite) {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _openInviteDialog(WidgetTester tester) async {
  await tester.tap(find.text('I have an invite'));
  await tester.pumpAndSettle();
}

Future<void> _openManualDialog(WidgetTester tester) async {
  await tester.tap(find.text('Connect to a Space'));
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester, String name) async {
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  group('invite dialog', () {
    testWidgets('empty: nothing typed, Continue disabled', (tester) async {
      await _pumpOnboarding(tester);
      await _openInviteDialog(tester);
      await _finish(tester, 'invite-dialog-empty-desktop');
    });

    testWidgets('address error', (tester) async {
      await _pumpOnboarding(tester);
      await _openInviteDialog(tester);
      await tester.enterText(find.byType(TextField).first, 'not a url');
      await tester.enterText(find.byType(TextField).at(1), 'CODE1');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(
        find.text('That does not look like a server address.'),
        findsOneWidget,
      );
      await _finish(tester, 'invite-dialog-address-error-desktop');
    });

    testWidgets('scheme refused', (tester) async {
      await _pumpOnboarding(tester);
      await _openInviteDialog(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'http://chat.example.com',
      );
      await tester.enterText(find.byType(TextField).at(1), 'CODE1');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Use https'), findsOneWidget);
      await _finish(tester, 'invite-dialog-scheme-refused-desktop');
    });

    // The same copy for expired, spent, revoked and never-issued, so codes cannot be mined by their failure message.
    testWidgets('code unusable', (tester) async {
      await _pumpOnboarding(tester, checkBody: const {'usable': false});
      await _openInviteDialog(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'https://chat.example',
      );
      await tester.enterText(find.byType(TextField).at(1), 'DEADCODE1');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not usable'), findsOneWidget);
      await _finish(tester, 'invite-dialog-code-unusable-desktop');
    });

    testWidgets('unreachable server', (tester) async {
      await _pumpOnboarding(tester, throwOnCheck: true);
      await _openInviteDialog(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'https://chat.example',
      );
      await tester.enterText(find.byType(TextField).at(1), 'CODE1');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Could not reach that server.'), findsOneWidget);
      await _finish(tester, 'invite-dialog-unreachable-desktop');
    });

    /// http/error.rs's ApiError::Internal is always this exact fixed
    /// string, never a route-specific message - the real answer the
    /// catch-all branch this exercises would actually receive for a 500.
    testWidgets('server refused with its own message', (tester) async {
      await _pumpOnboarding(
        tester,
        checkBody: {'error': _errorStrings.internalError},
        checkStatus: 500,
      );
      await _openInviteDialog(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'https://chat.example',
      );
      await tester.enterText(find.byType(TextField).at(1), 'CODE1');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(sentenceCase(_errorStrings.internalError)),
        findsOneWidget,
      );
      await _finish(tester, 'invite-dialog-server-refused-desktop');
    });
  });

  group('manual server dialog', () {
    testWidgets('empty: nothing typed yet', (tester) async {
      await _pumpOnboarding(tester);
      await _openManualDialog(tester);
      await _finish(tester, 'manual-server-dialog-empty-desktop');
    });

    testWidgets('address error', (tester) async {
      await _pumpOnboarding(tester);
      await _openManualDialog(tester);
      await tester.enterText(find.byType(TextField), 'not a url');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(
        find.text('That does not look like a server address.'),
        findsOneWidget,
      );
      await _finish(tester, 'manual-server-dialog-address-error-desktop');
    });

    testWidgets('scheme refused', (tester) async {
      await _pumpOnboarding(tester);
      await _openManualDialog(tester);
      await tester.enterText(find.byType(TextField), 'http://chat.example.com');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Use https'), findsOneWidget);
      await _finish(tester, 'manual-server-dialog-scheme-refused-desktop');
    });
  });

  group('server identity (TOFU)', () {
    testWidgets('first connection to an address shows its fingerprint', (
      tester,
    ) async {
      await _pumpOnboarding(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
          'identity': _identityA,
        },
      );
      await _openManualDialog(tester);
      await tester.enterText(find.byType(TextField), 'https://chat.example');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm this server'), findsOneWidget);
      await _finish(tester, 'tofu-first-connect-fingerprint-desktop');
    });

    testWidgets("a key that no longer matches what was pinned before, checkbox "
        "unacknowledged so the risky action stays disabled", (tester) async {
      final keyStore = InMemoryKeyStore();
      await keyStore.put(
        'server_identity:https://chat.example',
        _identityA['public_key'] as String,
      );
      await _pumpOnboarding(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
          'identity': _identityB,
        },
        keyStore: keyStore,
      );
      await _openManualDialog(tester);
      await tester.enterText(find.byType(TextField), 'https://chat.example');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text("This server's identity changed"), findsOneWidget);
      await _finish(tester, 'tofu-identity-changed-unacknowledged-desktop');
    });

    testWidgets('the same warning once the acknowledgement checkbox is ticked, '
        'which is what unlocks the risky action', (tester) async {
      final keyStore = InMemoryKeyStore();
      await keyStore.put(
        'server_identity:https://chat.example',
        _identityA['public_key'] as String,
      );
      await _pumpOnboarding(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
          'identity': _identityB,
        },
        keyStore: keyStore,
      );
      await _openManualDialog(tester);
      await tester.enterText(find.byType(TextField), 'https://chat.example');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await _finish(tester, 'tofu-identity-changed-acknowledged-desktop');
    });

    testWidgets('the mismatch warning at phone width', (tester) async {
      final keyStore = InMemoryKeyStore();
      await keyStore.put(
        'server_identity:https://chat.example',
        _identityA['public_key'] as String,
      );
      await _pumpOnboarding(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
          'identity': _identityB,
        },
        keyStore: keyStore,
        viewport: const Size(390, 844),
      );
      await _openManualDialog(tester);
      await tester.enterText(find.byType(TextField), 'https://chat.example');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text("This server's identity changed"), findsOneWidget);
      await _finish(tester, 'tofu-identity-changed-unacknowledged-phone');
    });
  });
}
