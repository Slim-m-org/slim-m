// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A viewer's YouTube player held on the room: a drift past two seconds
/// seeks, the room's play and pause are followed, a change the viewer makes
/// in the player is theirs alone until they rejoin, and a new video loads.
/// See docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/voice/providers/watch_room.dart';
import 'package:slimm_app/src/features/voice/providers/youtube_watch_sync.dart';

import '../video/fake_video_player.dart';

final _t0 = DateTime.utc(2026, 11, 20, 20);

WatchRoom _room({
  String id = 'dQw4w9WgXcQ',
  bool playing = true,
  Duration position = const Duration(seconds: 30),
  DateTime? sampled,
  int epoch = 1,
}) => WatchRoom(
  botUserId: 'yt',
  provider: api.WatchProvider.youtube,
  itemId: id,
  title: 'A Clip',
  playing: playing,
  position: position,
  sampledAtMs: (sampled ?? _t0).millisecondsSinceEpoch,
  epoch: epoch,
  ttl: const Duration(seconds: 30),
  clockOffset: Duration.zero,
  duration: const Duration(minutes: 4),
);

class _Rig {
  _Rig() {
    sync = YoutubeWatchSync(
      player: player,
      load: (id, start, title) async => loads.add((id: id, start: start)),
      clock: () => now,
      loadedId: 'dQw4w9WgXcQ',
    );
  }

  final player = FakeVideoPlayer();
  final loads = <({String id, Duration start})>[];
  DateTime now = _t0;
  late final YoutubeWatchSync sync;

  void advance(Duration by) => now = now.add(by);
}

void main() {
  test(
    'a player more than two seconds off the room seeks, one closer does not',
    () async {
      final rig = _Rig();
      await rig.sync.onRoom(_room());
      rig.player
        ..emit(const VideoPlaying())
        ..reported = const Duration(seconds: 31);
      await rig.sync.step();
      expect(rig.player.reported, const Duration(seconds: 31));

      rig.player.reported = const Duration(seconds: 20);
      rig.advance(const Duration(seconds: 1));
      await rig.sync.step();
      expect(rig.player.reported, const Duration(seconds: 31));
    },
  );

  test('the room pausing pauses the player, and playing plays it', () async {
    final rig = _Rig();
    await rig.sync.onRoom(_room());
    rig.player.emit(const VideoPlaying());
    rig.advance(const Duration(seconds: 5));
    await rig.sync.onRoom(_room(playing: false, sampled: rig.now));
    expect(rig.player.pauses, 1);
    rig.player.emit(const VideoPaused());
    expect(rig.sync.state.localAt, isNull);

    await rig.sync.onRoom(_room(sampled: rig.now));
    expect(rig.player.plays, 2, reason: 'once to start, once to resume');
  });

  test(
    'the autoplay of a load into a paused room is undone, not taken as the viewer playing',
    () async {
      final rig = _Rig();
      await rig.sync.onRoom(_room(playing: false));
      rig.player.emit(const VideoPlaying());
      await rig.sync.step();
      expect(rig.player.pauses, 1);
      expect(rig.sync.state.localAt, isNull);
    },
  );

  test(
    'a pause the viewer makes is theirs until they rejoin the room',
    () async {
      final rig = _Rig();
      await rig.sync.onRoom(_room());
      rig.player.emit(const VideoPlaying());
      rig.advance(const Duration(seconds: 10));
      rig.player.emit(const VideoPaused());
      expect(rig.sync.state.localAt, const Duration(seconds: 40));

      rig.player.reported = Duration.zero;
      rig.advance(const Duration(seconds: 2));
      await rig.sync.step();
      expect(rig.player.plays, 1, reason: 'the sync stops steering');
      expect(rig.player.reported, Duration.zero);
      expect(rig.sync.state.localAt, const Duration(seconds: 42));

      await rig.sync.rejoin();
      expect(rig.sync.state.localAt, isNull);
      expect(rig.player.reported, const Duration(seconds: 42));
      expect(rig.player.plays, 2);
    },
  );

  test('a seek in the room moves the player at once', () async {
    final rig = _Rig();
    await rig.sync.onRoom(_room());
    rig.player.emit(const VideoPlaying());
    rig.advance(const Duration(seconds: 1));
    await rig.sync.onRoom(
      _room(position: const Duration(minutes: 2), sampled: rig.now, epoch: 2),
    );
    expect(rig.player.reported, const Duration(minutes: 2));
  });

  test('a new video loads where the room is', () async {
    final rig = _Rig();
    await rig.sync.onRoom(_room());
    await rig.sync.onRoom(
      _room(id: 'jNQXAC9IVRw', position: const Duration(seconds: 3), epoch: 2),
    );
    expect(rig.loads.single, (
      id: 'jNQXAC9IVRw',
      start: const Duration(seconds: 3),
    ));
  });

  test('a video that refuses embedding says so', () async {
    final rig = _Rig();
    await rig.sync.onRoom(_room());
    rig.player.emit(const VideoFailed(150));
    expect(rig.sync.state.failure?.embeddingRefused, isTrue);
  });
}
