// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A member's profile as a phone sheet and as a desktop popover, away, with a
/// colour banner and with an image banner, in both themes. PNGs are written
/// only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/banner_bytes.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/presence_view.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

api.UserProfile _profile({required bool image}) => api.UserProfile(
  id: 'user-claude',
  username: 'Claude',
  displayName: 'Claude',
  createdAt: 1790000000000,
  roles: const ['admin'],
  profileColor: 2,
  bannerUpdatedAt: image ? 1 : null,
);

Future<Uint8List> _bannerPng() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 900, 300),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(900, 300), const [
        Color(0xFF2B5FA8),
        Color(0xFFE08A3C),
      ]),
  );
  final image = await recorder.endRecording().toImage(900, 300);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _capture(
  WidgetTester tester, {
  required double width,
  required bool dark,
  required bool image,
  required String name,
}) async {
  tester.view.physicalSize = Size(width + 40, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final png = await tester.runAsync(_bannerPng);
  final profile = _profile(image: image);
  final tokens = dark ? AppTokens.dark : AppTokens.light;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        membersProvider.overrideWith((ref) async => [profile]),
        presenceForProvider.overrideWith((ref, id) => AppPresence.away),
        bannerBytesProvider.overrideWith((ref, key) async => png),
      ],
      child: MaterialApp(
        theme: buildTheme(dark ? Brightness.dark : Brightness.light, tokens),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: RepaintBoundary(
                key: snapshotBoundary,
                child: ColoredBox(
                  color: tokens.surfaceRaised,
                  child: MemberProfileBody(
                    profile: profile,
                    compact: width < 400,
                    onDone: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 3; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  for (final dark in const [true, false]) {
    for (final image in const [false, true]) {
      for (final (label, width) in const [
        ('phone', 390.0),
        ('desktop', 320.0),
      ]) {
        final name =
            'member-profile-away-$label-${dark ? 'dark' : 'light'}-'
            '${image ? 'image' : 'colour'}';
        testWidgets(name, (tester) async {
          await _capture(
            tester,
            width: width,
            dark: dark,
            image: image,
            name: name,
          );
        });
      }
    }
  }
}
