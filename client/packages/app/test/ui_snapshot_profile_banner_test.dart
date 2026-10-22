// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings > Profile with a colour banner and with an image banner, at phone
/// and desktop width in both themes. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/banner_bytes.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';

import 'features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController;
import 'ui_snapshot_support.dart';

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

api.Me _me({required bool image}) => api.Me(
  id: 'user-nick',
  username: 'nick',
  displayName: 'Nick',
  createdAt: 1790000000000,
  permissions: 0,
  profileColor: 0,
  avatarUpdatedAt: 1,
  bannerUpdatedAt: image ? 1 : null,
);

void main() {
  setUpAll(loadRealFonts);

  for (final theme in const ['dark', 'light']) {
    for (final viewport in phoneAndDesktop) {
      for (final image in const [false, true]) {
        final kind = image ? 'image' : 'colour';
        testWidgets('profile banner $kind at $viewport ($theme)', (
          tester,
        ) async {
          final png = await tester.runAsync(_bannerPng);
          await renderSurface(
            tester,
            '/settings',
            viewport,
            theme,
            'profile-banner-settings-$kind-$viewport-$theme',
            overrides: [
              voiceControllerProvider.overrideWith(
                (ref) => SnapshotVoiceController(ref, const VoiceState()),
              ),
              meProvider.overrideWith((ref) async => _me(image: image)),
              bannerBytesProvider.overrideWith((ref, key) async => png),
            ],
            afterSettle: (tester) async {
              await tester.tap(find.text('Profile').first);
              await tester.pump();
              for (var i = 0; i < 3; i++) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 100)),
                );
                await tester.pump(const Duration(milliseconds: 100));
              }
            },
          );
        });
      }
    }
  }
}
