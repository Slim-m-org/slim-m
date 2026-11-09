// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A member's colour banner follows the phone sheet's rounded top corners.
///
/// The owner's iPhone screenshot showed the banner as a square-cornered
/// rectangle under a strip of sheet colour, its corners poking past the
/// sheet's curve. Pixels are read from the real sheet, since a widget-tree
/// check cannot see a corner that was never clipped.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_sync.dart';
import '../../support/reduced_motion_harness.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _pink = Color(0xFFE0699A);

const _maya = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
  profileColorRgb: 0xE0699A,
);

final _boundary = GlobalKey();

Future<void> _openSheet(
  WidgetTester tester,
  Brightness brightness, {
  bool moderating = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(StubSyncController.new),
      databaseProvider.overrideWith((ref) async => db),
      myPermissionsProvider.overrideWithValue(moderating ? 0x7fffffff : 0),
      membersProvider.overrideWith((ref) async => [_maya]),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: reducedMotionRouterApp(
        container: container,
        router: GoRouter(
          initialLocation: '/channels',
          routes: [
            GoRoute(
              path: '/channels',
              builder: (context, state) => Scaffold(
                body: GestureDetector(
                  onTap: () => showMemberProfile(
                    context,
                    profile: _maya,
                    initiallyModerating: moderating,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ],
        ),
        brightness: brightness,
        size: const Size(390, 844),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<Color Function(double x, double y)> _pixels(WidgetTester tester) async {
  late ui.Image image;
  late ByteData bytes;
  await tester.runAsync(() async {
    final render =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    image = await render.toImage();
    bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });
  return (double x, double y) {
    final i = (y.round() * image.width + x.round()) * 4;
    return Color.fromARGB(
      bytes.getUint8(i + 3),
      bytes.getUint8(i),
      bytes.getUint8(i + 1),
      bytes.getUint8(i + 2),
    );
  };
}

/// The first row, down the page's blank right side, that is no longer the dimmed page.
double _sheetTop(Color Function(double x, double y) pixel) {
  final page = pixel(300, 0);
  var y = 0.0;
  while (pixel(300, y) == page) {
    y++;
  }
  return y;
}

void main() {
  for (final brightness in Brightness.values) {
    group('on a ${brightness.name} phone sheet', () {
      testWidgets('the banner stops at the rounded top corners', (
        tester,
      ) async {
        await _openSheet(tester, brightness);
        final pixel = await _pixels(tester);
        final top = _sheetTop(pixel);

        // Down the sheet's left and right edge the curve has not reached the edge for 20 rows.
        for (var row = 0; row < 18; row++) {
          expect(pixel(1, top + row), isNot(_pink), reason: 'left, row $row');
          expect(
            pixel(388, top + row),
            isNot(_pink),
            reason: 'right, row $row',
          );
        }
      });

      testWidgets('the banner starts at the very top of the sheet', (
        tester,
      ) async {
        await _openSheet(tester, brightness);
        final pixel = await _pixels(tester);
        final top = _sheetTop(pixel);

        expect(pixel(60, top + 3), _pink);
        expect(pixel(330, top + 3), _pink);
      });

      testWidgets('Moderate clears the handle it has no banner under', (
        tester,
      ) async {
        await _openSheet(tester, brightness, moderating: true);
        final top = _sheetTop(await _pixels(tester));

        expect(
          tester.getTopLeft(find.byKey(const Key('member-moderate-view'))).dy,
          greaterThanOrEqualTo(top + kSheetHandleExtent),
        );
      });

      testWidgets('the sheet still hugs its content', (tester) async {
        await _openSheet(tester, brightness);

        // A handle laid over the banner once stretched the sheet to the whole window.
        expect(_sheetTop(await _pixels(tester)), greaterThan(200));
      });
    });
  }
}
