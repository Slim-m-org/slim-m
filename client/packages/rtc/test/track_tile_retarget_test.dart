// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A video tile rebuilt with another room or identity must follow it: the
/// widget used to keep listening to the room it was first built with.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/camera_view.dart';
import 'package:slimm_rtc/src/screen_share_view.dart';

class _CountingEmitter extends lk.EventsEmitter<lk.RoomEvent> {
  int active = 0;

  @override
  lk.CancelListenFunc listen(FutureOr<void> Function(lk.RoomEvent) onEvent) {
    active++;
    final cancel = super.listen(onEvent);
    return () async {
      active--;
      await cancel();
    };
  }
}

class _SpyRoom extends lk.Room {
  _SpyRoom() {
    baseline = _emitter.active;
  }

  final _emitter = _CountingEmitter();
  late final int baseline;

  @override
  lk.EventsEmitter<lk.RoomEvent> get events => _emitter;

  int get tileListeners => _emitter.active - baseline;
}

void main() {
  late _SpyRoom first;
  late _SpyRoom second;

  setUp(() {
    first = _SpyRoom();
    second = _SpyRoom();
  });

  tearDown(() async {
    await first.dispose();
    await second.dispose();
  });

  testWidgets('CameraView moves its room subscription with the room', (
    tester,
  ) async {
    final facing = ValueNotifier(CameraFacing.front);
    addTearDown(facing.dispose);
    Widget view(lk.Room room) => MaterialApp(
          home: CameraView(room: room, identity: 'me', facing: facing),
        );

    await tester.pumpWidget(view(first));
    expect(first.tileListeners, 1);
    await tester.pumpWidget(view(second));

    expect(first.tileListeners, 0, reason: 'the old room is still heard');
    expect(second.tileListeners, 1, reason: 'the new room is not heard');
  });

  testWidgets('CameraView follows a swapped facing notifier', (tester) async {
    debugResetCameraViewBuildCounts();
    final before = ValueNotifier(CameraFacing.front);
    final after = ValueNotifier(CameraFacing.front);
    addTearDown(before.dispose);
    addTearDown(after.dispose);
    Widget view(ValueNotifier<CameraFacing> facing) => MaterialApp(
          home: CameraView(room: first, identity: 'me', facing: facing),
        );

    await tester.pumpWidget(view(before));
    await tester.pumpWidget(view(after));
    final builds = debugCameraViewBuildCounts['me']!;
    after.value = CameraFacing.back;
    await tester.pump();

    expect(debugCameraViewBuildCounts['me'], builds + 1);
    final stale = debugCameraViewBuildCounts['me'];
    before.value = CameraFacing.back;
    await tester.pump();
    expect(debugCameraViewBuildCounts['me'], stale, reason: 'old one heard');
  });

  testWidgets('ScreenShareView moves its room subscription with the room', (
    tester,
  ) async {
    Widget view(lk.Room room) =>
        MaterialApp(home: ScreenShareView(room: room, identity: 'me'));

    await tester.pumpWidget(view(first));
    await tester.pumpWidget(view(second));

    expect(first.tileListeners, 0, reason: 'the old room is still heard');
    expect(second.tileListeners, 1, reason: 'the new room is not heard');
  });
}
