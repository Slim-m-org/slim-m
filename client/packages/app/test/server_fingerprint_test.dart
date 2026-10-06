// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fingerprint screen renders values a possibly-hostile server supplied, so
/// a malformed identity must look wrong rather than throw.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/server_fingerprint_step.dart';
import 'package:slimm_app/src/widgets/server_identity_changed_step.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.dark, AppTokens.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// Both step widgets build their own [Scaffold] (see the library doc on
/// each), so hosting them inside `_host`'s Scaffold-in-a-scroll-view gives
/// the inner one unbounded height; a bare [MaterialApp] is enough.
Widget _appHost(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.dark, AppTokens.dark),
  home: child,
);

const _identity = api.ServerIdentity(
  publicKey: 'k',
  fingerprint: 'deadbeefcafebabefeedface1337d00d',
  fingerprintGroups: [
    'dead',
    'beef',
    'cafe',
    'babe',
    'feed',
    'face',
    '1337',
    'd00d',
  ],
  colorStrip: [0, 1, 2, 3],
);

void main() {
  testWidgets('a short fingerprint and an out-of-range swatch do not throw', (
    tester,
  ) async {
    // What a server that wants this screen to fail would send: too few groups
    // for the two rows, and colour indices past the six-entry palette.
    await tester.pumpWidget(
      _host(
        FingerprintDisplay(
          identity: const api.ServerIdentity(
            publicKey: 'not-really-base64',
            fingerprint: 'short',
            fingerprintGroups: ['dead', 'beef'],
            colorStrip: [99, -3, 0, 6],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('dead'),
      findsNothing,
      reason: 'a key that cannot be hashed shows no server-chosen code',
    );
  });

  testWidgets('an empty identity renders nothing rather than throwing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        FingerprintDisplay(
          identity: const api.ServerIdentity(
            publicKey: '',
            fingerprint: '',
            fingerprintGroups: [],
            colorStrip: [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the first-connect confirmation claims no step count it cannot keep true',
    (tester) async {
      await tester.pumpWidget(
        _appHost(
          ServerFingerprintStep(
            address: Uri.parse('https://chat.example'),
            identity: _identity,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining(RegExp(r'STEP \d+ OF \d+')),
        findsNothing,
        reason:
            'this check fires 0, 1 or more times depending on what is '
            'already pinned, so it has no fixed place in the join flow',
      );
    },
  );

  testWidgets(
    'the identity-changed warning claims no step count it cannot keep true',
    (tester) async {
      await tester.pumpWidget(
        _appHost(
          ServerIdentityChangedStep(
            address: Uri.parse('https://chat.example'),
            identity: _identity,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining(RegExp(r'STEP \d+ OF \d+')), findsNothing);
    },
  );
}
