// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One viewer's direct play for one call: whether it is offered, whether it is
/// on, and the player while it is.
///
/// The shared screen share is always the floor. Turning this on holds the
/// bot's share unwatched, so the viewer is never subscribed to it and playing
/// the file at once (decision 0014 protects a bounded number of decode
/// sessions), and any failure puts the share back. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../format.dart' show formatPlaybackTime;
import 'direct_play_corrector.dart';
import 'direct_play_eligibility.dart';
import 'direct_player.dart';
import 'jellyfin_direct_client.dart';
import 'watch_room.dart';

enum DirectPlayPhase { off, signIn, connecting, playing }

class DirectPlayState {
  const DirectPlayState({
    this.phase = DirectPlayPhase.off,
    this.enabled = false,
    this.block,
    this.notice,
    this.signInError,
    this.localPause,
    this.checking = false,
  });

  final DirectPlayPhase phase;

  /// The viewer's saved choice; it stays on across a fall back so the next party tries again.
  final bool enabled;
  final DirectPlayBlock? block;

  /// Why the viewer is back on the shared stream after trying, until they act.
  final String? notice;
  final String? signInError;

  /// Where the room is while this viewer is paused on their own.
  final Duration? localPause;
  final bool checking;

  bool get active =>
      phase == DirectPlayPhase.connecting || phase == DirectPlayPhase.playing;

  DirectPlayState copyWith({
    DirectPlayPhase? phase,
    bool? enabled,
    Object? block = _keep,
    Object? notice = _keep,
    Object? signInError = _keep,
    Object? localPause = _keep,
    bool? checking,
  }) => DirectPlayState(
    phase: phase ?? this.phase,
    enabled: enabled ?? this.enabled,
    block: identical(block, _keep) ? this.block : block as DirectPlayBlock?,
    notice: identical(notice, _keep) ? this.notice : notice as String?,
    signInError: identical(signInError, _keep)
        ? this.signInError
        : signInError as String?,
    localPause: identical(localPause, _keep)
        ? this.localPause
        : localPause as Duration?,
    checking: checking ?? this.checking,
  );
}

const Object _keep = Object();

/// How often the player is compared with the room.
const Duration kDirectPlayPoll = Duration(seconds: 1);

/// How often a viewer says they are playing directly; the server forgets after 20 seconds.
const Duration kDirectPlayReport = Duration(seconds: 10);

class DirectPlayEnvironment {
  const DirectPlayEnvironment({
    required this.slimm,
    required this.selfId,
    required this.clock,
    required this.client,
    required this.makePlayer,
    required this.loadCredential,
    required this.saveCredential,
    required this.saveEnabled,
    required this.holdShare,
    required this.releaseShare,
    required this.directPlaySupported,
  });

  final api.SlimmApi slimm;
  final String selfId;
  final DateTime Function() clock;
  final JellyfinDirectClient client;
  final DirectPlayer Function() makePlayer;
  final Future<JellyfinSession?> Function(String baseUrl) loadCredential;
  final Future<void> Function(String baseUrl, JellyfinSession session)
  saveCredential;
  final Future<void> Function(bool enabled) saveEnabled;
  final void Function(String identity) holdShare;
  final void Function(String identity) releaseShare;

  /// False where the original file cannot be played untranscoded, such as a browser.
  final bool directPlaySupported;
}

class DirectPlayController extends StateNotifier<DirectPlayState> {
  DirectPlayController(this._env, this._channelId, {bool enabled = false})
    : super(DirectPlayState(enabled: enabled));

  final DirectPlayEnvironment _env;
  final String _channelId;

  WatchRoom? _room;
  DirectPlayer? _player;
  JellyfinSession? _credential;
  DirectPlayCorrector _corrector = DirectPlayCorrector();
  Timer? _poll;
  Timer? _report;
  String? _probedUrl;
  bool? _reachable;
  bool? _canSee;
  String? _canSeeItem;
  String? _heldBot;
  Duration? _lastPosition;
  DateTime? _lastMovedAt;
  bool _disposed = false;

  // After a fall back the viewer decides when to try again, or every tick would restart the player.
  bool _cooledOff = false;

  /// The picture while connecting or playing.
  DirectPlayer? get player => _player;

  /// The current state, for callers that hold the controller itself.
  DirectPlayState get current => state;

  /// Why the last sign-in was turned down, or null if it was not.
  String? get signInError => state.signInError;

  /// The sharer whose stream this viewer's player stands in for, while it does.
  String? get heldBot => _heldBot;

  /// The latest room sample; the provider feeds every change here.
  Future<void> onRoom(WatchRoom? room) async {
    final previous = _room;
    _room = room;
    if (room == null) {
      await _stopPlaying(retract: true);
      state = state.copyWith(
        phase: DirectPlayPhase.off,
        block: null,
        notice: null,
        localPause: null,
        checking: false,
      );
      return;
    }
    if (previous != null && previous.itemId != room.itemId) {
      _cooledOff = false;
      if (state.active) await _stopPlaying(retract: true);
    }
    final offer = room.directPlay;
    if (offer == null) {
      if (state.active) {
        await _fallBack(
          'The party stopped offering source quality. Back on the shared stream.',
        );
      }
      state = state.copyWith(block: null);
      return;
    }
    await _evaluate(offer);
    if (state.enabled && state.block == null && !state.active && !_cooledOff) {
      await _begin(offer);
    }
  }

  Future<void> _evaluate(api.WatchDirectPlay offer) async {
    final link = linkBlock(offer, _env.selfId);
    if (link != null) {
      state = state.copyWith(block: link);
      return;
    }
    if (_probedUrl != offer.baseUrl) {
      _probedUrl = offer.baseUrl;
      state = state.copyWith(checking: true);
      _reachable =
          _env.directPlaySupported &&
          await _env.client.reachable(offer.baseUrl);
      if (_disposed) return;
      state = state.copyWith(checking: false);
    }
    state = state.copyWith(
      block: firstBlock(
        offer: offer,
        userId: _env.selfId,
        probe: DirectPlayProbe(
          reachable: _reachable,
          canSeeItem: _canSeeItem == _room?.itemId ? _canSee : null,
        ),
      ),
    );
  }

  /// Forgets what the device learned about the media server and asks again.
  Future<void> recheck() async {
    _cooledOff = false;
    _probedUrl = null;
    _canSee = null;
    _canSeeItem = null;
    state = state.copyWith(notice: null);
    final room = _room;
    if (room != null) await onRoom(room);
  }

  /// The viewer turns direct play on.
  Future<void> enable() async {
    _cooledOff = false;
    await _env.saveEnabled(true);
    state = state.copyWith(enabled: true, notice: null, signInError: null);
    final offer = _room?.directPlay;
    if (offer != null && state.block == null) await _begin(offer);
  }

  /// The viewer turns it off, or chooses the shared stream.
  Future<void> disable() async {
    await _env.saveEnabled(false);
    await _stopPlaying(retract: true);
    state = state.copyWith(
      enabled: false,
      phase: DirectPlayPhase.off,
      notice: null,
      signInError: null,
      localPause: null,
    );
  }

  Future<void> signIn(String username, String password) async {
    final offer = _room?.directPlay;
    if (offer == null) return;
    state = state.copyWith(signInError: null);
    try {
      final session = await _env.client.signIn(
        offer.baseUrl,
        username: username,
        password: password,
      );
      _credential = session;
      await _env.saveCredential(offer.baseUrl, session);
    } on JellyfinSignInRefused {
      state = state.copyWith(
        signInError: 'That name and password were not accepted.',
      );
      return;
    } on Object {
      state = state.copyWith(
        signInError: 'Could not reach Jellyfin to sign in.',
      );
      return;
    }
    state = state.copyWith(phase: DirectPlayPhase.off);
    unawaited(_begin(offer));
  }

  void cancelSignIn() {
    unawaited(_env.saveEnabled(false));
    state = state.copyWith(
      enabled: false,
      phase: DirectPlayPhase.off,
      signInError: null,
    );
  }

  Future<void> _begin(api.WatchDirectPlay offer) async {
    final room = _room;
    if (room == null || state.active) return;
    _credential ??= await _env.loadCredential(offer.baseUrl);
    final credential = _credential;
    if (credential == null) {
      state = state.copyWith(phase: DirectPlayPhase.signIn);
      return;
    }
    state = state.copyWith(phase: DirectPlayPhase.connecting, notice: null);
    try {
      if (_canSeeItem != room.itemId) {
        _canSee = await _env.client.canSee(
          offer.baseUrl,
          credential,
          room.itemId,
        );
        _canSeeItem = room.itemId;
      }
      if (_canSee == false) {
        state = state.copyWith(
          phase: DirectPlayPhase.off,
          block: DirectPlayBlock.cannotSee,
        );
        return;
      }
      _heldBot = room.botUserId;
      _env.holdShare(room.botUserId);
      final source = _env.client.original(
        offer.baseUrl,
        credential,
        room.itemId,
      );
      final player = _env.makePlayer();
      _player = player;
      _corrector = DirectPlayCorrector();
      await player.open(source.url, source.headers, _target(room));
      if (player.isPlaying == false && room.playing) await player.play();
      if (_disposed || _player != player) return;
      _lastPosition = null;
      _lastMovedAt = null;
      _poll = Timer.periodic(kDirectPlayPoll, (_) => unawaited(_step()));
      _report = Timer.periodic(kDirectPlayReport, (_) => _reportViewing(true));
      state = state.copyWith(phase: DirectPlayPhase.playing);
      _reportViewing(true);
    } on Object catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'Direct play could not start',
        error,
        stack,
      );
      await _fallBack(
        'Could not play from Jellyfin. Back on the shared stream.',
      );
    }
  }

  Duration _target(WatchRoom room) => room.positionAt(_env.clock());

  @visibleForTesting
  Future<void> debugStep() => _step();

  Future<void> _step() async {
    final room = _room;
    final player = _player;
    if (room == null ||
        player == null ||
        state.phase != DirectPlayPhase.playing) {
      return;
    }
    final now = _env.clock();
    if (room.isStale(now)) {
      await _stopPlaying(retract: true);
      state = state.copyWith(phase: DirectPlayPhase.off, localPause: null);
      return;
    }
    final target = room.positionAt(now);
    if (state.localPause != null) {
      state = state.copyWith(localPause: target);
      return;
    }
    final correction = _corrector.step(
      target: target,
      actual: player.position,
      epoch: room.epoch,
      roomPlaying: room.playing,
      stuck: _stuck(player, room.playing, now),
      now: now,
    );
    await _apply(correction, room, player);
  }

  bool _stuck(DirectPlayer player, bool roomPlaying, DateTime now) {
    final position = player.position;
    if (_lastPosition == null || position != _lastPosition) {
      _lastPosition = position;
      _lastMovedAt = now;
    }
    if (player.isBuffering) return true;
    final since = _lastMovedAt;
    return roomPlaying &&
        since != null &&
        now.difference(since) > kDirectPlayPoll * 3;
  }

  Future<void> _apply(
    Correction correction,
    WatchRoom room,
    DirectPlayer player,
  ) async {
    switch (correction) {
      case NoCorrection():
        if (!room.playing && player.isPlaying) await player.pause();
        if (room.playing && !player.isPlaying) await player.play();
      case SetRate(:final rate):
        await player.setRate(rate);
      case SeekTo(:final position):
        await player.seek(position);
        if (room.playing && !player.isPlaying) await player.play();
        if (!room.playing && player.isPlaying) await player.pause();
      case GiveUp(:final reason):
        await _fallBack(switch (reason) {
          GiveUpReason.drifting =>
            'Your player could not stay with the room. Back on the shared stream.',
          GiveUpReason.stalled =>
            'Playback stalled. Back on the shared stream.',
        });
    }
  }

  /// Pauses only this viewer; the room carries on without them.
  Future<void> pauseLocally() async {
    final room = _room;
    final player = _player;
    if (room == null || player == null || !state.active) return;
    await player.pause();
    state = state.copyWith(localPause: _target(room));
  }

  /// Rejoins the room's position after a local pause.
  Future<void> rejoin() async {
    final room = _room;
    final player = _player;
    if (room == null || player == null) return;
    state = state.copyWith(localPause: null);
    _corrector = DirectPlayCorrector();
    await player.seek(_target(room));
    if (room.playing) await player.play();
  }

  Future<void> _fallBack(String notice) async {
    _cooledOff = true;
    await _stopPlaying(retract: true);
    state = state.copyWith(
      phase: DirectPlayPhase.off,
      notice: notice,
      localPause: null,
    );
  }

  Future<void> _stopPlaying({required bool retract}) async {
    _poll?.cancel();
    _report?.cancel();
    _poll = _report = null;
    final player = _player;
    _player = null;
    if (retract && (player != null || _heldBot != null)) _reportViewing(false);
    final bot = _heldBot;
    _heldBot = null;
    if (bot != null) _env.releaseShare(bot);
    if (player != null) await player.dispose();
  }

  void _reportViewing(bool direct) {
    unawaited(
      _env.slimm.reportWatchViewing(_channelId, direct: direct).catchError((
        Object error,
        StackTrace stack,
      ) {
        api.AppLog.swallowed(
          api.LogTag.voice,
          'Could not report direct play',
          error,
          stack,
        );
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stopPlaying(retract: true));
    super.dispose();
  }
}

String directPlayPauseLine(Duration roomPosition) =>
    'You are paused, the room is at ${formatPlaybackTime(roomPosition)}';
