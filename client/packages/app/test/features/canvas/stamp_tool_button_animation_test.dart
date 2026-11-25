// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The armed animated stamp on the Stamp tool's button plays only while that tool is the active one.
///
/// The owner, 2026-11-25: "unselecting stamp with an animated emoji selected keeps the animation moving its kindve annoying".
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/armed_stamp.dart';
import 'package:slimm_app/src/features/canvas/widgets/stamp_tool_button.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_content.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_images.dart';
import 'package:slimm_design_system/design_system.dart';

/// Two 1x1 frames, red then blue, 100ms apart, looping forever.
Uint8List _twoFrameGif() => base64Decode(
  'R0lGODlhAQABAIAAAP8AAAAA/yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAQABAAAC'
  'AkQBACH5BAAKAAAALAAAAAABAAEAAAICTAEAOw==',
);

const _partyId = '01a0459d-3038-73f0-b530-73a38681d4ae';

Future<Set<int>> _framesDrawn(WidgetTester tester, {int steps = 12}) async {
  final frames = <int>{};
  for (var i = 0; i < steps; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 60));
    for (final drawn in tester.allRenderObjects.whereType<RenderImage>()) {
      if (drawn.image != null) frames.add(drawn.image.hashCode);
    }
  }
  return frames;
}

Future<void> _pump(WidgetTester tester, {required bool active}) async {
  final cache = StampImageCache(
    fetchStill: (_) => throw UnimplementedError(),
    fetchOriginal: (_) => throw UnimplementedError(),
    customEmojiBytes: (_) async => _twoFrameGif(),
    customIndex: () => const {'party': _partyId},
  );
  addTearDown(cache.clear);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stampImageCacheProvider.overrideWithValue(cache),
        armedStampProvider.overrideWith(_ArmedParty.new),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Center(
          child: StampToolButton(
            active: active,
            semanticLabel: 'Stamp',
            onPressed: (_) {},
          ),
        ),
      ),
    ),
  );
}

class _ArmedParty extends ArmedStampController {
  @override
  ArmedStamp build() => const ArmedStamp(content: EmojiStamp(_partyId));
}

void main() {
  testWidgets('with the Stamp tool active the armed sample plays', (
    tester,
  ) async {
    await _pump(tester, active: true);
    expect(await _framesDrawn(tester), hasLength(greaterThan(1)));
  });

  testWidgets('with another tool active the armed sample holds still', (
    tester,
  ) async {
    await _pump(tester, active: false);
    expect(await _framesDrawn(tester), hasLength(1));
  });

  testWidgets('arming the tool again resumes the animation', (tester) async {
    await _pump(tester, active: false);
    expect(await _framesDrawn(tester), hasLength(1), reason: 'baseline');

    await _pump(tester, active: true);
    expect(await _framesDrawn(tester), hasLength(greaterThan(1)));
  });
}
