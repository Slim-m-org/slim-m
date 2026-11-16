// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gap around a presence mark is cut out of the avatar, so it shows the
/// surface the avatar sits on. It used to be a disc painted in surfaceBase,
/// which read as a dark blob behind the phone glyph on any other surface.
library;

import 'dart:math' as math;
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

  testWidgets('the marks cut into the dot take the surface the caller names',
      (tester) async {
    Future<Color?> dotBackdrop({Color? surface}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: AppAvatar(
            name: 'Nadia',
            size: AppAvatarSize.s56,
            status: AppPresence.dnd,
            surfaceColor: surface,
          ),
        ),
      );
      return tester
          .widget<AppStatusDot>(
              find.byWidgetPredicate((w) => w is AppStatusDot))
          .backgroundColor;
    }

    expect(await dotBackdrop(), AppTokens.dark.surfaceBase);
    expect(
      await dotBackdrop(surface: AppTokens.dark.surfaceRaised),
      AppTokens.dark.surfaceRaised,
    );
  });

  for (final presence in [
    AppPresence.online,
    AppPresence.away,
    AppPresence.dnd,
    AppPresence.offline,
    AppPresence.hidden,
  ]) {
    testWidgets(
        'the ${presence.name} mark sits inside its round cutout, '
        'a whole ring of surface around it', (tester) async {
      final ring = await _haloRing(tester, presence);
      expect(ring.where((pixel) => pixel != _surface), isEmpty);
    });
  }
}

/// The pixels on a circle midway through the halo, all the way round the mark.
Future<List<Color>> _haloRing(WidgetTester tester, AppPresence presence) async {
  const size = AppAvatarSize.s56;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
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
              surfaceColor: _surface,
            ),
          ),
        ),
      ),
    ),
  );
  const geometry = AppAvatarGeometry(size);
  final centre = geometry.dotCenter + const Offset(_inset, _inset);
  final radius = geometry.markDiameter / 2 + AppAvatarGeometry.dotHalo / 2;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  final pixels = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _scale);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    image.dispose();
    Color at(Offset point) {
      final i = (point.dy.floor() * width + point.dx.floor()) * 4;
      return Color.fromARGB(
        data!.getUint8(i + 3),
        data.getUint8(i),
        data.getUint8(i + 1),
        data.getUint8(i + 2),
      );
    }

    return [
      for (var step = 0; step < 72; step++)
        at((centre + Offset.fromDirection(step * math.pi / 36, radius)) *
            _scale),
    ];
  });
  return pixels!;
}
