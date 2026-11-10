// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of the home pane (no channel chosen) on desktop, the
/// channel rail's phone drawer, the connection banner and the accessibility
/// variants of the shell.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// no overflow.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/whats_new/providers/whats_new_controller.dart';
import 'package:slimm_app/src/widgets/space_icon.dart';
import 'package:slimm_design_system/design_system.dart' show MotionOverride;

import '../support/fake_sync.dart';
import '../ui_snapshot_support.dart';
import 'ui_review_shell_and_rail_data.dart';
import 'ui_review_shell_and_rail_actions.dart';
import 'ui_review_shell_and_rail_support.dart';

const _phone = ShellWindow.phone;
const _desktop = ShellWindow.desktop;
const _release = '0.127.0';
const _blurb =
    'A small place for the Pinewood crew to talk, hang out in voice and '
    'sketch ideas together.';

Override _space({bool described = true, bool icon = true}) =>
    serverInfoProvider.overrideWith(
      (ref) async => api.Version(
        name: 'slim-m',
        version: _release,
        protocol: 1,
        spaceName: 'Pinewood Collective',
        spaceDescription: described ? _blurb : null,
        iconUpdatedAt: icon ? 5 : null,
      ),
    );

Future<Uint8List> _iconPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 128, 128),
    Paint()..color = const Color(0xFF2F6B4F),
  );
  canvas.drawCircle(
    const Offset(64, 64),
    38,
    Paint()..color = const Color(0xFFE8F3EC),
  );
  canvas.drawCircle(
    const Offset(64, 64),
    18,
    Paint()..color = const Color(0xFF2F6B4F),
  );
  final image = await recorder.endRecording().toImage(128, 128);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Future<Override> _icon(WidgetTester tester) async {
  final png = (await tester.runAsync(_iconPng))!;
  return spaceIconBytesProvider.overrideWith((ref, at) async => png);
}

ShellStep _prefs({required String lastSeen}) => (tester, scene) async {
  SharedPreferences.setMockInitialValues({
    lastSeenWhatsNewVersionKey: lastSeen,
  });
  PackageInfo.setMockInitialValues(
    appName: 'slim-m',
    packageName: 'top.npcserver.slimm',
    version: _release,
    buildNumber: '1',
    buildSignature: '',
  );
};

ShellStep _homeSeed({required String lastSeen, bool unread = false}) =>
    (tester, scene) async {
      await _prefs(lastSeen: lastSeen)(tester, scene);
      await (unread ? seedBusyRailWithUnread : seedBusyRail)(tester, scene);
    };

class _AlwaysReduceMotion extends MotionPreferenceController {
  _AlwaysReduceMotion(super.ref) {
    state = MotionOverride.alwaysReduce;
  }
}

Override _connection(SyncStatus status) => syncControllerProvider.overrideWith(
  (ref) => StubSyncController(ref, status),
);

void main() {
  setUpAll(loadRealFonts);

  group('shell-home-pane', () {
    testWidgets('welcome card, setup still owed', (tester) async {
      await shootShell(
        tester,
        _desktop,
        ShellCase(
          surface: 'shell-home-pane',
          state: 'welcome-card',
          route: '/channels',
          overrides: [_space(), await _icon(tester)],
          seed: (tester, scene) async {
            await _homeSeed(lastSeen: _release)(tester, scene);
            // No message of its own is what makes setup still owed.
            await scene.db.delete(scene.db.messages).go();
          },
          arrange: (tester, scene) => letImagesDecode(tester),
        ),
      );
    });

    testWidgets('update card after an upgrade', (tester) async {
      await shootShell(
        tester,
        _desktop,
        ShellCase(
          surface: 'shell-home-pane',
          state: 'update-card',
          route: '/channels',
          overrides: [_space(), await _icon(tester)],
          seed: _homeSeed(lastSeen: '0.126.1'),
          arrange: (tester, scene) => letImagesDecode(tester),
        ),
      );
    });

    testWidgets('what is waiting', (tester) async {
      await shootShell(
        tester,
        _desktop,
        ShellCase(
          surface: 'shell-home-pane',
          state: 'unread',
          route: '/channels',
          overrides: [_space(), await _icon(tester)],
          seed: _homeSeed(lastSeen: _release, unread: true),
          arrange: (tester, scene) => letImagesDecode(tester),
        ),
      );
    });

    testWidgets('a Space with no icon or description', (tester) async {
      await shootShell(
        tester,
        _desktop,
        ShellCase(
          surface: 'shell-home-pane',
          state: 'no-icon',
          route: '/channels',
          overrides: [_space(described: false, icon: false)],
          seed: _homeSeed(lastSeen: _release),
        ),
      );
    });
  });

  group('drawer-rail-phone', () {
    testWidgets('the rail pulled over a channel', (tester) async {
      await shootShell(
        tester,
        _phone,
        ShellCase(
          surface: 'drawer-rail-phone',
          route: '/channels/c-general',
          seed: seedBusyRailWithUnread,
          arrange: (tester, scene) async {
            await tester.dragFrom(const Offset(2, 400), const Offset(320, 0));
            await tester.pump(const Duration(milliseconds: 350));
          },
        ),
      );
    });
  });

  group('banner-rail-connection', () {
    for (final (state, status) in [
      ('connecting', SyncStatus.connecting),
      ('offline', SyncStatus.offline),
    ]) {
      testWidgets('the banner while $state', (tester) async {
        await shootShell(
          tester,
          _phone,
          ShellCase(
            surface: 'banner-rail-connection',
            state: state,
            route: '/channels/c-general',
            overrides: [_connection(status)],
          ),
        );
      });
    }
  });

  group('shell-cross-cutting-variants', () {
    for (final window in ShellWindow.values) {
      testWidgets('high contrast on a channel, ${window.slug}', (tester) async {
        await shootShell(
          tester,
          window,
          const ShellCase(
            surface: 'shell-cross-cutting-variants',
            state: 'high-contrast-channel',
            route: '/channels/c-general',
            highContrast: true,
            seed: seedBusyRailWithUnread,
          ),
        );
      });

      testWidgets('high contrast in settings, ${window.slug}', (tester) async {
        await shootShell(
          tester,
          window,
          ShellCase(
            surface: 'shell-cross-cutting-variants',
            state: 'high-contrast-settings',
            route: '/settings',
            highContrast: true,
            arrange: (tester, scene) async {
              await tester.tap(find.text('Appearance').first);
              await tester.pump(const Duration(milliseconds: 350));
            },
          ),
        );
      });

      testWidgets('reduced motion on a channel, ${window.slug}', (
        tester,
      ) async {
        await shootShell(
          tester,
          window,
          ShellCase(
            surface: 'shell-cross-cutting-variants',
            state: 'reduced-motion-channel',
            route: '/channels/c-general',
            overrides: [
              motionPreferenceControllerProvider.overrideWith(
                _AlwaysReduceMotion.new,
              ),
            ],
            seed: seedBusyRailWithUnread,
          ),
        );
      });
    }
  });
}
