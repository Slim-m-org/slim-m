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
import 'package:slimm_api/api.dart' as api;

import '../../../format.dart' show formatPlaybackTime;
import 'direct_play_corrector.dart';
import 'direct_play_eligibility.dart';
import 'direct_play_environment.dart';
import 'direct_play_state.dart';
import 'direct_player.dart';
import 'jellyfin_direct_client.dart';
import 'watch_room.dart';

export 'direct_play_environment.dart';
export 'direct_play_state.dart';

/// How often the player is compared with the room.
const Duration kDirectPlayPoll = Duration(seconds: 1);

/// How many polls in a row may fail before the viewer is put back on the shared stream.
const int kDirectPlayStepFailures = 3;

/// How often a viewer says they are playing directly; the server forgets after 20 seconds.
const Duration kDirectPlayReport = Duration(seconds: 10);

/// The direct-play state machine for one channel; [DirectPlay] mirrors its state into riverpod.
class DirectPlayController {
  DirectPlayController(this._env, this._channelId, {bool enabled = false})
    : _state = DirectPlayState(enabled: enabled);

  DirectPlayState _state;
  void Function(DirectPlayState)? _onChange;

  DirectPlayState get state => _state;

  set state(DirectPlayState next) {
    _state = next;
    _onChange?.call(next);
  }

  /// Receives every later state; one listener, the provider's notifier.
  void onChange(void Function(DirectPlayState) listener) =>
      _onChange = listener;

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
  String? _credentialUrl;
  bool _stepping = false;
  int _stepFailures = 0;
  bool _disposed = false;

  // Bumped whenever what a pending connect was started for is gone; each await in _begin re-checks it.
  int _generation = 0;
  int? _beginningGeneration;
  int _signInGeneration = 0;

  // After a fall back the viewer decides when to try again, or every tick would restart the player.
  bool _cooledOff = false;

  /// The picture while connecting or playing.
  DirectPlayer? get player => _player;

  /// The current state, for callers that hold the controller itself.
  DirectPlayState get current => state;

  /// Why the last sign-in was turned down, or null if it was not.
  String? get signInError => state.signInError;

  /// The server a sign-in goes to right now, which the party's bot chooses.
  String? get signInBaseUrl => _room?.directPlay?.baseUrl;

  /// The sharer whose stream this viewer's player stands in for, while it does.
  String? get heldBot => _heldBot;

  /// The latest room sample; the provider feeds every change here.
  Future<void> onRoom(WatchRoom? room) async {
    final previous = _room;
    _room = room;
    if (room == null || previous?.itemId != room.itemId) _generation++;
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
      if (state.active) {
        await _stopPlaying(retract: true);
        state = state.copyWith(phase: DirectPlayPhase.off, localPause: null);
      }
    }
    final offer = room.directPlay;
    if (offer == null) {
      _generation++;
      if (state.active) {
        await _fallBack(
          'The party stopped offering source quality. Back on the shared stream.',
        );
      }
      state = state.copyWith(block: null);
      return;
    }
    await _evaluate(offer);
    final waiting = state.phase == DirectPlayPhase.signIn;
    if (state.enabled &&
        state.block == null &&
        !state.active &&
        !waiting &&
        !_cooledOff) {
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
    final asked = _signInGeneration;
    state = state.copyWith(signInError: null);
    try {
      final session = await _env.client.signIn(
        offer.baseUrl,
        username: username,
        password: password,
      );
      if (asked != _signInGeneration || _disposed) return;
      _credential = session;
      _credentialUrl = offer.baseUrl;
      await _env.saveCredential(offer.baseUrl, session);
    } on JellyfinSignInRefused {
      state = state.copyWith(
        signInError: 'That name and password were not accepted.',
      );
      return;
    } on Object catch (error, stack) {
      _swallowed('Jellyfin did not answer the sign in', error, stack);
      state = state.copyWith(
        signInError: 'Could not reach Jellyfin to sign in.',
      );
      return;
    }
    if (asked != _signInGeneration || _disposed) return;
    state = state.copyWith(phase: DirectPlayPhase.off);
    unawaited(_begin(offer));
  }

  void cancelSignIn() {
    _signInGeneration++;
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
    final generation = _generation;
    if (_beginningGeneration == generation) return;
    _beginningGeneration = generation;
    bool stale() => _disposed || generation != _generation;
    try {
      final credential = await _credentialFor(offer.baseUrl);
      if (stale()) return;
      if (credential == null) {
        state = state.copyWith(phase: DirectPlayPhase.signIn);
        return;
      }
      state = state.copyWith(phase: DirectPlayPhase.connecting, notice: null);
      if (_canSeeItem != room.itemId) {
        final canSee = await _env.client.canSee(
          offer.baseUrl,
          credential,
          room.itemId,
        );
        if (stale()) return;
        _canSee = canSee;
        _canSeeItem = room.itemId;
      }
      if (_canSee == false) {
        state = state.copyWith(
          phase: DirectPlayPhase.off,
          block: DirectPlayBlock.cannotSee,
        );
        return;
      }
      await _play(offer, room, credential, stale);
    } on JellyfinUnauthorized {
      if (!stale()) await _expire(offer.baseUrl);
    } on Object catch (error, stack) {
      if (stale()) return;
      _swallowed('Direct play could not start', error, stack);
      await _fallBack(
        'Could not play from Jellyfin. Back on the shared stream.',
      );
    } finally {
      if (_beginningGeneration == generation) _beginningGeneration = null;
    }
  }

  Future<void> _play(
    api.WatchDirectPlay offer,
    WatchRoom room,
    JellyfinSession credential,
    bool Function() stale,
  ) async {
    _heldBot = room.botUserId;
    _env.holdShare(room.botUserId);
    final source = _env.client.original(offer.baseUrl, credential, room.itemId);
    final player = _env.makePlayer();
    _player = player;
    _corrector = DirectPlayCorrector();
    await player.open(source.url, source.headers, _target(room));
    if (player.isPlaying == false && room.playing) await player.play();
    if (stale() || _player != player) return;
    _lastPosition = null;
    _lastMovedAt = null;
    _stepFailures = 0;
    _poll = Timer.periodic(kDirectPlayPoll, (_) => unawaited(_step()));
    _report = Timer.periodic(kDirectPlayReport, (_) => _reportViewing(true));
    state = state.copyWith(phase: DirectPlayPhase.playing);
    _reportViewing(true);
  }

  Future<JellyfinSession?> _credentialFor(String baseUrl) async {
    if (_credentialUrl != baseUrl) {
      _credential = await _env.loadCredential(baseUrl);
      _credentialUrl = baseUrl;
    }
    return _credential;
  }

  Future<void> _expire(String baseUrl) async {
    _credential = null;
    _canSeeItem = null;
    try {
      await _env.forgetCredential(baseUrl);
    } on Object catch (error, stack) {
      _swallowed('Could not delete an expired Jellyfin login', error, stack);
    }
    state = state.copyWith(
      phase: DirectPlayPhase.signIn,
      notice: 'Your Jellyfin sign-in expired. Sign in again.',
    );
  }

  Duration _target(WatchRoom room) => room.positionAt(_env.clock());

  @visibleForTesting
  Future<void> debugStep() => _step();

  Future<void> _step() async {
    if (_stepping) return;
    _stepping = true;
    try {
      await _tick();
      _stepFailures = 0;
    } on Object catch (error, stack) {
      _swallowed('Direct play could not follow the room', error, stack);
      if (++_stepFailures >= kDirectPlayStepFailures && !_disposed) {
        await _fallBack(
          'Your player stopped responding. Back on the shared stream.',
        );
      }
    } finally {
      _stepping = false;
    }
  }

  Future<void> _tick() async {
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

  /// The call ended: stop playing but keep the viewer's saved choice for the next party.
  Future<void> stopForCallEnd() async {
    _generation++;
    await _stopPlaying(retract: true);
    state = state.copyWith(
      phase: DirectPlayPhase.off,
      localPause: null,
      notice: null,
    );
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
    _generation++;
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
        _swallowed('Could not report direct play', error, stack);
      }),
    );
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _onChange = null;
    unawaited(_stopPlaying(retract: true));
  }
}

String directPlayPauseLine(Duration roomPosition) =>
    'You are paused, the room is at ${formatPlaybackTime(roomPosition)}';

void _swallowed(String reason, Object error, StackTrace stack) =>
    api.AppLog.swallowed(api.LogTag.voice, reason, error, stack);
