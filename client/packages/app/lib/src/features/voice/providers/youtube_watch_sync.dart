// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps this viewer's YouTube player on the room's video, position and play
/// state, through nothing but [EmbeddedVideoPlayer].
///
/// The bot is the only authority: a pause, play or seek made in YouTube's own
/// controls, or a pause the app makes because the window left the screen, is
/// this viewer's alone, and steering stops until they rejoin the room. The
/// embed has no fine playback rate, so a drift past two seconds is a seek and
/// anything under it is left alone (decision 0050 section 6's tolerance).
/// See docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';

import '../../video/providers/embedded_video_player.dart';
import 'watch_room.dart';

/// How often the player is compared with the room.
const Duration kYoutubeWatchPoll = Duration(seconds: 1);

/// The spread between viewers the room tolerates before a seek.
const Duration kYoutubeDriftSeeks = Duration(seconds: 2);

/// A seek takes a moment to land, so the next one waits at least this long.
const Duration _kSeekSettle = Duration(seconds: 3);

/// A state change this soon after the sync asked for it is the sync's own.
const Duration _kOwnChange = Duration(seconds: 3);

class YoutubeWatchState {
  const YoutubeWatchState({this.localAt, this.failure});

  /// Where the room is while this viewer watches on their own, else null.
  final Duration? localAt;

  /// Why the video cannot play here, once the player said so.
  final VideoFailed? failure;
}

/// Loads [videoId] at [start] in whatever hosts the player.
typedef WatchVideoLoad =
    Future<void> Function(String videoId, Duration start, String title);

class YoutubeWatchSync {
  YoutubeWatchSync({
    required EmbeddedVideoPlayer player,
    required WatchVideoLoad load,
    required DateTime Function() clock,
    required String loadedId,
  }) : _player = player,
       _load = load,
       _clock = clock,
       _loadedId = loadedId,
       _loadedAt = clock() {
    _events = player.events.listen(_onEvent);
  }

  final EmbeddedVideoPlayer _player;
  final WatchVideoLoad _load;
  final DateTime Function() _clock;
  late final StreamSubscription<VideoPlayerEvent> _events;
  void Function(YoutubeWatchState)? _onChange;

  WatchRoom? _room;
  String _loadedId;
  DateTime _loadedAt;
  int? _epoch;
  bool _playing = false;
  bool _buffering = false;
  bool _ended = false;
  bool _local = false;
  bool? _asked;
  DateTime? _askedAt;
  DateTime? _seekedAt;
  YoutubeWatchState _state = const YoutubeWatchState();
  Timer? _poll;

  YoutubeWatchState get state => _state;

  /// One listener, the widget that shows the state.
  void onChange(void Function(YoutubeWatchState) listener) =>
      _onChange = listener;

  void _emit(YoutubeWatchState next) {
    _state = next;
    _onChange?.call(next);
  }

  void start() =>
      _poll ??= Timer.periodic(kYoutubeWatchPoll, (_) => unawaited(step()));

  /// The latest room sample; a new video or epoch is applied at once.
  Future<void> onRoom(WatchRoom room) async {
    final before = _room;
    _room = room;
    final now = _clock();
    if (room.itemId != _loadedId) {
      _loadedId = room.itemId;
      _loadedAt = now;
      _epoch = room.epoch;
      _ended = false;
      _local = false;
      _emit(const YoutubeWatchState());
      await _load(room.itemId, room.positionAt(now), room.title);
      return;
    }
    final moved = _epoch != null && _epoch != room.epoch;
    _epoch = room.epoch;
    if (_local) return;
    if (moved) {
      _ended = false;
      await _seek(room.positionAt(now), now);
    }
    if (before?.playing != room.playing || moved) await _follow(room, now);
  }

  /// One comparison of the player with the room.
  Future<void> step() async {
    final room = _room;
    if (room == null || _state.failure != null) return;
    final now = _clock();
    final target = room.positionAt(now);
    if (_local) {
      _emit(YoutubeWatchState(localAt: target));
      return;
    }
    if (_buffering || _ended) return;
    await _follow(room, now);
    final actual = await _player.position();
    final settled =
        _seekedAt == null || now.difference(_seekedAt!) >= _kSeekSettle;
    if ((target - actual).abs() > kYoutubeDriftSeeks && settled) {
      await _seek(target, now);
    }
  }

  Future<void> _follow(WatchRoom room, DateTime now) async {
    if (room.playing == _playing) return;
    final waiting =
        _asked == room.playing &&
        _askedAt != null &&
        now.difference(_askedAt!) < _kOwnChange;
    if (waiting) return;
    _ask(room.playing, now);
    await (room.playing ? _player.play() : _player.pause());
  }

  void _ask(bool playing, DateTime now) {
    _asked = playing;
    _askedAt = now;
  }

  Future<void> _seek(Duration target, DateTime now) async {
    _seekedAt = now;
    await _player.seekTo(target);
  }

  /// Watches the room again from where it is now.
  Future<void> rejoin() async {
    final room = _room;
    if (room == null) return;
    final now = _clock();
    _local = false;
    _ended = false;
    _emit(const YoutubeWatchState());
    await _seek(room.positionAt(now), now);
    _ask(room.playing, now);
    await (room.playing ? _player.play() : _player.pause());
  }

  void _onEvent(VideoPlayerEvent event) {
    final now = _clock();
    switch (event) {
      case VideoPlaying():
        _buffering = false;
        _ended = false;
        _setPlaying(true, now);
      case VideoPaused():
        _buffering = false;
        _setPlaying(false, now);
      case VideoBuffering():
        _buffering = true;
      case VideoEnded():
        _buffering = false;
        _ended = true;
        _playing = false;
      case VideoFailed():
        _emit(YoutubeWatchState(failure: event));
      case VideoReady() || VideoFullscreenChanged():
        break;
    }
  }

  void _setPlaying(bool playing, DateTime now) {
    _playing = playing;
    final room = _room;
    final askedFor =
        _asked == playing &&
        _askedAt != null &&
        now.difference(_askedAt!) <= _kOwnChange;
    if (askedFor) _asked = null;
    // The embed autoplays every load, which is the sync's own doing too.
    final loading = now.difference(_loadedAt) <= _kOwnChange && playing;
    if (room == null || _local || askedFor || loading) return;
    if (room.playing != playing) {
      _local = true;
      _emit(YoutubeWatchState(localAt: room.positionAt(now)));
    }
  }

  void dispose() {
    _poll?.cancel();
    _onChange = null;
    unawaited(_events.cancel());
  }
}
