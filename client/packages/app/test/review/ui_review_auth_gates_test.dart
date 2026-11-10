// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screens that stop or interrupt the app: the client-too-old screen, the
/// app lock and the not-found page. Phone and desktop, dark and light, one
/// mount each.
///
/// The lock is reached by overriding the provider that trips it over a real
/// route; the too-old screen is mounted with each install format in turn,
/// since the gate itself reads the host's.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_app/src/desktop/rpm_updater.dart';
import 'package:slimm_app/src/features/auth/widgets/client_too_old_gate.dart';
import 'package:slimm_app/src/providers/app_lock_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/not_found_screen.dart';
import 'package:slimm_platform/platform.dart';

import '../support/mock_app_version.dart';
import 'review_auth_support.dart';
import 'review_support.dart';

/// A dnf stand-in: [hold] parks the upgrade, [ok] and [detail] answer it.
class _Dnf implements RpmUpdater {
  _Dnf({this.ok = true, this.detail = '', this.hold});

  final bool ok;
  final String detail;
  final Completer<void>? hold;

  @override
  Future<RpmUpdateResult> apply({String? currentVersion}) async {
    await hold?.future;
    return RpmUpdateResult(ok: ok, detail: detail);
  }

  @override
  Future<bool> repoEnabled() async => true;

  @override
  Future<String?> installedVersion() async => '0.121.0';
}

Future<void> _tooOld(
  WidgetTester tester,
  String viewport,
  String state, {
  InstallFormat format = InstallFormat.rpm,
  bool isWeb = false,
  RpmUpdater? rpm,
  ReviewAct? act,
}) => reviewWidget(
  tester,
  surface: 'app-client-too-old',
  state: state,
  viewport: viewport,
  build: (context) =>
      ClientTooOldScreen(format: format, rpm: rpm, isWeb: isWeb),
  overrides: [
    appInfoProvider.overrideWith(
      (ref) async => PackageInfo(
        appName: 'slim-m',
        packageName: 'top.npcserver.slimm',
        version: '0.121.0',
        buildNumber: '1',
      ),
    ),
  ],
  act: act,
);

Future<void> _tapUpdate(WidgetTester tester, ReviewHandles _) =>
    tapLabel(tester, 'Update now');

/// The app lock, locked, with [unlock] standing in for the biometric prompt.
class _StubLock extends AppLockController {
  _StubLock(super.ref, this._unlock) {
    state = true;
  }

  final Future<bool> Function() _unlock;

  @override
  Future<bool> unlock({String reason = 'Unlock slim-m'}) => _unlock();
}

Future<void> _lock(
  WidgetTester tester,
  String viewport,
  String state,
  Future<bool> Function() unlock, {
  ReviewAct? act,
}) => reviewRoute(
  tester,
  surface: 'overlay-app-lock',
  state: state,
  viewport: viewport,
  act: act,
  overrides: [
    appLockControllerProvider.overrideWith((ref) => _StubLock(ref, unlock)),
  ],
);

void main() {
  setUpAll(loadRealFonts);
  setUpAll(mockAppVersion);

  reviewCases(
    'app-client-too-old',
    state: 'rpm',
    body: (tester, viewport) => _tooOld(tester, viewport, 'rpm'),
  );

  reviewCases(
    'app-client-too-old',
    state: 'flatpak',
    body: (tester, viewport) =>
        _tooOld(tester, viewport, 'flatpak', format: InstallFormat.flatpak),
  );

  reviewCases(
    'app-client-too-old',
    state: 'web',
    body: (tester, viewport) => _tooOld(
      tester,
      viewport,
      'web',
      format: InstallFormat.unknown,
      isWeb: true,
    ),
  );

  reviewCases(
    'app-client-too-old',
    state: 'tarball',
    body: (tester, viewport) =>
        _tooOld(tester, viewport, 'tarball', format: InstallFormat.tarball),
  );

  reviewCases(
    'app-client-too-old',
    state: 'busy',
    body: (tester, viewport) {
      final hold = Completer<void>();
      return whileHolding(
        tester,
        hold,
        () => _tooOld(
          tester,
          viewport,
          'busy',
          rpm: _Dnf(hold: hold),
          act: (tester, handles) async {
            await reduceMotion(tester, handles);
            await _tapUpdate(tester, handles);
          },
        ),
      );
    },
  );

  reviewCases(
    'app-client-too-old',
    state: 'error',
    body: (tester, viewport) => _tooOld(
      tester,
      viewport,
      'error',
      rpm: _Dnf(
        ok: false,
        detail:
            'Error: Transaction failed. Package slim-m-client conflicts with '
            'an installed package and cannot be resolved without removing it.',
      ),
      act: _tapUpdate,
    ),
  );

  reviewCases(
    'app-client-too-old',
    state: 'installed',
    body: (tester, viewport) =>
        _tooOld(tester, viewport, 'installed', rpm: _Dnf(), act: _tapUpdate),
  );

  // The stub answers without unlocking, which leaves the lock at rest: nothing in flight, nothing failed.
  reviewCases(
    'overlay-app-lock',
    state: 'locked',
    body: (tester, viewport) =>
        _lock(tester, viewport, 'locked', () async => true),
  );

  reviewCases(
    'overlay-app-lock',
    state: 'authenticating',
    body: (tester, viewport) {
      final hold = Completer<void>();
      return whileHolding(
        tester,
        hold,
        () => _lock(tester, viewport, 'authenticating', () async {
          await hold.future;
          return false;
        }, act: reduceMotion),
      );
    },
  );

  reviewCases(
    'overlay-app-lock',
    state: 'failed',
    body: (tester, viewport) =>
        _lock(tester, viewport, 'failed', () async => false),
  );

  reviewCases(
    'app-not-found',
    body: (tester, viewport) => reviewRoute(
      tester,
      surface: 'app-not-found',
      viewport: viewport,
      route: '/',
      allowNotFound: true,
      router: GoRouter(
        initialLocation: '/no-such-page',
        errorBuilder: (context, state) => const NotFoundScreen(),
        routes: [GoRoute(path: '/', builder: (context, _) => const SizedBox())],
      ),
    ),
  );
}
