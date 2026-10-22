// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gap around a presence mark is cut out of the avatar, so it shows the
/// surface the avatar sits on. It used to be a disc painted in surfaceBase,
/// which read as a dark blob behind the phone glyph on any other surface.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _surface = Color(0xFFFF0000);
const _boundary = Key('halo-boundary');
const _inset = 20.0;
const _scale = 4.0;

Future<Color> _haloGapPixel(
  WidgetTester tester, {
  required bool phone,
  AppPresence presence = AppPresence.online,
  Brightness brightness = Brightness.dark,
  bool above = false,
}) async {
  const size = AppAvatarSize.s36;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(
        brightness,
        brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
      ),
      home: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: _boundary,
          child: Container(
            color: _surface,
            padding: const EdgeInsets.all(_inset),
            child: AppAvatar(
              name: 'Nadia',
              size: size,
              status: presence,
              mobileOnly: phone,
            ),
          ),
        ),
      ),
    ),
  );
  final geometry = AppAvatarGeometry(size, phone: phone);
  // Straight right of the mark, inside the halo ring and past the avatar's edge.
  final gap = above
      ? Offset(0, -(geometry.markDiameter / 2 + AppAvatarGeometry.dotHalo / 2))
      : Offset(geometry.dotHaloRadius - 0.75, 0);
  final probe = geometry.dotCenter + gap + const Offset(_inset, _inset);
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _scale);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    image.dispose();
    final at = probe * _scale;
    final i = (at.dy.floor() * width + at.dx.floor()) * 4;
    return [for (var k = 0; k < 4; k++) data!.getUint8(i + k)];
  });
  return Color.fromARGB(bytes![3], bytes[0], bytes[1], bytes[2]);
}

void main() {
  for (final phone in [true, false]) {
    testWidgets('the halo shows the surface beneath (phone: $phone)', (
      tester,
    ) async {
      expect(await _haloGapPixel(tester, phone: phone), _surface);
    });
  }

  for (final presence in [
    AppPresence.online,
    AppPresence.away,
    AppPresence.dnd,
    AppPresence.offline,
    AppPresence.hidden,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'the gap above the ${presence.name} mark shows the surface '
          '(${brightness.name})', (tester) async {
        final pixel = await _haloGapPixel(
          tester,
          phone: false,
          presence: presence,
          brightness: brightness,
          above: true,
        );
        expect(pixel, _surface);
      });
    }
  }
}
