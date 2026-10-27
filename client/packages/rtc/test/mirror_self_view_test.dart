// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Mirror my view" only ever turns the local mirror off; a remote tile is
/// never mirrored whichever way it is set.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/camera_view.dart';

void main() {
  group('mirrorModeFor with mirrorSelf off', () {
    test('a local front camera is not mirrored', () {
      expect(
        mirrorModeFor(
          isLocal: true,
          facing: CameraFacing.front,
          mirrorSelf: false,
        ),
        lk.VideoViewMirrorMode.off,
      );
    });

    test('a local front camera still mirrors by default', () {
      expect(
        mirrorModeFor(isLocal: true, facing: CameraFacing.front),
        lk.VideoViewMirrorMode.mirror,
      );
    });

    test('a remote camera is never mirrored either way', () {
      for (final mirrorSelf in [true, false]) {
        expect(
          mirrorModeFor(
            isLocal: false,
            facing: CameraFacing.front,
            mirrorSelf: mirrorSelf,
          ),
          lk.VideoViewMirrorMode.off,
        );
      }
    });
  });

  group('MirrorSelfViewScope', () {
    Future<bool> read(WidgetTester tester, {bool? mirror}) async {
      late bool seen;
      Widget probe = Builder(
        builder: (context) {
          seen = MirrorSelfViewScope.of(context);
          return const SizedBox.shrink();
        },
      );
      if (mirror != null) {
        probe = MirrorSelfViewScope(mirror: mirror, child: probe);
      }
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: probe,
      ));
      return seen;
    }

    testWidgets('mirrors when nothing sets it', (tester) async {
      expect(await read(tester), isTrue);
    });

    testWidgets('follows the value above it', (tester) async {
      expect(await read(tester, mirror: false), isFalse);
      expect(await read(tester, mirror: true), isTrue);
    });
  });

  testWidgets('a camera view redraws when the choice flips', (tester) async {
    debugResetCameraViewBuildCounts();
    final room = lk.Room();
    final facing = ValueNotifier(CameraFacing.front);
    addTearDown(facing.dispose);
    // One instance across both pumps, so only the scope can force the rebuild.
    final camera = CameraView(room: room, identity: 'me', facing: facing);
    Widget view({required bool mirror}) => Directionality(
          textDirection: TextDirection.ltr,
          child: MirrorSelfViewScope(mirror: mirror, child: camera),
        );

    await tester.pumpWidget(view(mirror: true));
    final before = debugCameraViewBuildCounts['me'];
    await tester.pumpWidget(view(mirror: false));

    expect(debugCameraViewBuildCounts['me'], greaterThan(before!));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(room.dispose);
  });
}
