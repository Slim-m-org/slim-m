// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The server's client floor (decision 0025) and the one screen it is
/// allowed to put in front of a working session.
///
/// The comparison is deliberately paranoid about the "cannot tell" cases,
/// because every one of them is a reason to keep running rather than a
/// reason to stop: a floor that fails open is an inconvenience, one that
/// fails closed is an app nobody can use on a bad network.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/rpm_updater.dart';
import 'package:slimm_app/src/providers/client_floor.dart';
import 'package:slimm_app/src/widgets/client_too_old_gate.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

/// A dnf that answers [ok] without touching anything.
class _Dnf implements RpmUpdater {
  _Dnf({this.ok = true, this.detail = ''});

  final bool ok;
  final String detail;
  var applied = false;

  @override
  Future<RpmUpdateResult> apply({String? currentVersion}) async {
    applied = true;
    return RpmUpdateResult(ok: ok, detail: detail);
  }

  @override
  Future<bool> repoEnabled() async => true;

  @override
  Future<String?> installedVersion() async => '1.0.0';
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  InstallFormat format = InstallFormat.rpm,
  RpmUpdater? rpm,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: ClientTooOldScreen(format: format, rpm: rpm),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('clientFloorFor', () {
    test('no floor at all is fine, which is every server before this', () {
      expect(
        clientFloorFor(minClientVersion: null, clientVersion: '0.1.0'),
        ClientFloor.fine,
      );
    });

    test('a blank floor is no floor, not one nothing satisfies', () {
      expect(
        clientFloorFor(minClientVersion: '  ', clientVersion: '0.1.0'),
        ClientFloor.fine,
      );
    });

    test('below the floor is too old', () {
      expect(
        clientFloorFor(minClientVersion: '0.76.0', clientVersion: '0.75.0'),
        ClientFloor.tooOld,
      );
    });

    test('exactly the floor is allowed - it is a minimum, not a target', () {
      expect(
        clientFloorFor(minClientVersion: '0.76.0', clientVersion: '0.76.0'),
        ClientFloor.fine,
      );
    });

    test('above the floor is fine', () {
      expect(
        clientFloorFor(minClientVersion: '0.76.0', clientVersion: '1.0.0'),
        ClientFloor.fine,
      );
    });

    test('it compares numerically, not as text', () {
      expect(
        clientFloorFor(minClientVersion: '0.9.0', clientVersion: '0.10.0'),
        ClientFloor.fine,
        reason: '0.10.0 is newer than 0.9.0, though it sorts earlier',
      );
    });

    test('a build suffix is ignored on either side', () {
      expect(
        clientFloorFor(minClientVersion: '0.76.0', clientVersion: '0.76.0+21'),
        ClientFloor.fine,
      );
    });

    test('an unreadable version never blocks, on either side', () {
      expect(
        clientFloorFor(minClientVersion: 'latest', clientVersion: '0.75.0'),
        ClientFloor.unknown,
      );
      expect(
        clientFloorFor(minClientVersion: '0.76.0', clientVersion: ''),
        ClientFloor.unknown,
        reason: 'PackageInfo returns an empty version on some Linux builds',
      );
    });
  });

  group('the gate', () {
    testWidgets('only a floor that was read and beaten blocks anything', (
      tester,
    ) async {
      for (final state in [
        const AsyncValue<ClientFloor>.loading(),
        const AsyncValue<ClientFloor>.data(ClientFloor.fine),
        const AsyncValue<ClientFloor>.data(ClientFloor.unknown),
      ]) {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              clientFloorProvider.overrideWith((ref) => _never(state)),
            ],
            child: MaterialApp(
              theme: buildTheme(Brightness.dark, AppTokens.dark),
              home: const ClientTooOldGate(child: Text('the app')),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('the app'), findsOneWidget, reason: '$state');
      }
    });

    testWidgets('below the floor, the app is replaced outright', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clientFloorProvider.overrideWith((ref) async => ClientFloor.tooOld),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: const ClientTooOldGate(child: Text('the app')),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('the app'), findsNothing);
      expect(find.text('This version can no longer connect'), findsOneWidget);
    });
  });

  group('the screen', () {
    testWidgets('an rpm can finish the update from here', (tester) async {
      final dnf = _Dnf();
      await _pumpScreen(tester, rpm: dnf);

      expect(find.text('Update now'), findsOneWidget);
      await tester.tap(find.text('Update now'));
      await tester.pumpAndSettle();

      expect(dnf.applied, isTrue);
      expect(find.textContaining('Restart slim-m'), findsOneWidget);
    });

    testWidgets('a failed install says why and stays offerable', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        rpm: _Dnf(ok: false, detail: 'Error: Transaction failed'),
      );

      await tester.tap(find.text('Update now'));
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.textContaining('Transaction failed'), findsOneWidget);
      expect(
        tester
            .widget<AppButton>(find.widgetWithText(AppButton, 'Update now'))
            .disabled,
        isFalse,
        reason: 'a failure that cannot be retried is a dead end',
      );
    });

    testWidgets('a format that cannot install offers the release instead', (
      tester,
    ) async {
      await _pumpScreen(tester, format: InstallFormat.tarball);
      expect(find.text('Open the release'), findsOneWidget);
      expect(find.text('Update now'), findsNothing);
    });

    testWidgets('there is no way past it', (tester) async {
      await _pumpScreen(tester);
      expect(find.text('Not now'), findsNothing);
      expect(find.text('Later'), findsNothing);
      expect(find.text('Continue'), findsNothing);
    });
  });
}

/// A provider override that stays in [state] forever, so a loading gate can
/// be asserted on without racing a real future.
Future<ClientFloor> _never(AsyncValue<ClientFloor> state) => state.hasValue
    ? Future.value(state.value)
    : Completer<ClientFloor>().future;
