// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The YouTube party's stage slot: it plays the room's video in the host this
/// device has, says when the viewer went their own way and lets them rejoin,
/// and offers YouTube itself where the embed cannot play.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/video/providers/video_host_capability.dart';
import 'package:slimm_app/src/features/video/providers/watch_video_host.dart';
import 'package:slimm_app/src/features/voice/providers/watch_room.dart';
import 'package:slimm_app/src/features/voice/widgets/youtube_watch_stage.dart';
import 'package:slimm_design_system/design_system.dart';

import '../video/fake_video_player.dart';

final _t0 = DateTime.utc(2026, 11, 20, 20);

WatchRoom _room() => WatchRoom(
  botUserId: 'yt',
  provider: api.WatchProvider.youtube,
  itemId: 'dQw4w9WgXcQ',
  title: 'A Clip',
  playing: true,
  position: const Duration(seconds: 30),
  sampledAtMs: _t0.millisecondsSinceEpoch,
  epoch: 1,
  ttl: const Duration(seconds: 30),
  clockOffset: Duration.zero,
);

class _Rig {
  final player = FakeVideoPlayer();
  final rooms = StreamController<WatchRoom?>.broadcast();
  final opened = <({String id, Duration start})>[];
  int released = 0;
}

Future<_Rig> _pump(WidgetTester tester, {bool canPlay = true}) async {
  final rig = _Rig();
  addTearDown(rig.rooms.close);
  WatchVideoHandle factory(
    ProviderContainer container, {
    required String videoId,
    required Duration start,
    required String title,
    required void Function(Widget, void Function()) onShowFullscreen,
    required void Function() onHideFullscreen,
  }) {
    rig.opened.add((id: videoId, start: start));
    return WatchVideoHandle(
      player: rig.player,
      view: const ColoredBox(key: Key('fake-player'), color: Colors.red),
      load: (id, at, _) => rig.player.load(id, start: at),
      release: () async => rig.released++,
    );
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        watchClockProvider.overrideWithValue(() => _t0),
        videoHostKindProvider.overrideWith(
          (ref) async =>
              canPlay ? VideoHostKind.inline : VideoHostKind.external,
        ),
        watchVideoFactoryProvider.overrideWith(
          (ref, kind) => kind == VideoHostKind.external ? null : factory,
        ),
        watchRoomProvider.overrideWith((ref, id) => rig.rooms.stream),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SizedBox(
            width: 480,
            height: 270,
            child: YoutubeWatchStage(channelId: 'call-1'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  rig.rooms.add(_room());
  await tester.pump();
  await tester.pump();
  return rig;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets('plays the room video where the room is', (tester) async {
    final rig = await _pump(tester);
    expect(rig.opened.single, (
      id: 'dQw4w9WgXcQ',
      start: const Duration(seconds: 30),
    ));
    expect(find.byKey(const Key('fake-player')), findsOneWidget);
    await _unmount(tester);
    expect(rig.released, 1);
  });

  testWidgets('a pause of their own offers the viewer the room again', (
    tester,
  ) async {
    final rig = await _pump(tester);
    rig.player.emit(const VideoPlaying());
    await tester.pump(const Duration(seconds: 4));
    rig.player.emit(const VideoPaused());
    await tester.pump();
    expect(find.text(youtubeLocalLine(const Duration(seconds: 30))), findsOne);

    final plays = rig.player.plays;
    await tester.tap(find.text('Rejoin the room'));
    await tester.pump();
    expect(rig.player.plays, plays + 1);
    expect(find.text('Rejoin the room'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('a video whose owner refused embedding points to YouTube', (
    tester,
  ) async {
    final rig = await _pump(tester);
    rig.player.emit(const VideoFailed(150));
    await tester.pump();
    expect(
      find.text('This video can only be watched on YouTube.'),
      findsOneWidget,
    );
    await _unmount(tester);
  });

  testWidgets('a device with no player offers YouTube itself', (tester) async {
    final rig = await _pump(tester, canPlay: false);
    expect(rig.opened, isEmpty);
    expect(
      find.text('This device cannot play YouTube in the app.'),
      findsOneWidget,
    );
    expect(find.text('Open on YouTube'), findsOneWidget);
    await _unmount(tester);
  });
}
