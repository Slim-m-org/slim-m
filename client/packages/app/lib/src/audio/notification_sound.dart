// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The interface sounds (`assets/audio/notifications/`, what each one is
/// for is in `docs/design/sounds.md`) and the
/// seam a fake stands in for, so nothing that plays one ever touches real
/// audio hardware in a test.
///
/// `audioplayers` is the platform layer: the one Flutter audio package that
/// is cross-platform including Linux desktop (its own `audioplayers_linux`
/// plugin wraps GStreamer, a system library, rather than a bundled native
/// compile - the segfault-on-Wayland trap this project already hit was a
/// bundled FFI capturer, not a system-library plugin like this one) and lets
/// a caller name the iOS audio session category directly, which is what
/// keeps a chime from ever taking the session a live call already holds.
/// See docs/dependencies.md for the alternatives this was weighed against.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'releasable_player.dart';
import 'sound_audio_context.dart';

/// Which chime to play.
enum NotificationSound {
  directMessage('direct_message'),
  mention('mention'),
  groupMessage('group_message'),
  callRing('call_ring'),
  memberJoin('member_join'),
  memberLeave('member_leave'),
  error('error'),
  messageSent('message_sent'),
  messageReceivedInView('message_received_in_view'),
  selfJoin('self_join'),
  selfLeave('self_leave'),
  muteOn('mute_on'),
  muteOff('mute_off'),
  deafenOn('deafen_on'),
  deafenOff('deafen_off'),
  ringback('ringback');

  const NotificationSound(this._fileName);
  final String _fileName;

  /// The `rootBundle` key every asset resolves to, matching `pubspec.yaml`'s
  /// declared entries exactly - what `notification_sound_bundle_test.dart`
  /// loads directly to prove the file is really bundled.
  String get assetKey => 'assets/audio/notifications/$_fileName.wav';

  /// What `audioplayers`' `AssetSource` takes: its `AudioCache` prepends
  /// `assets/` itself (confirmed by reading `audio_cache.dart`), so passing
  /// the full [assetKey] here would look up `assets/assets/audio/...` and
  /// find nothing.
  String get _playerPath => 'audio/notifications/$_fileName.wav';
}

/// The seam a test fakes instead of touching a real audio device.
abstract class SoundPlayer {
  Future<void> play(NotificationSound sound);

  /// Starts [sound] looping until [stopLoop] - an incoming call's own shape,
  /// where one chime for the whole ring window is the wrong sound entirely.
  /// A separate call from [play]'s one-shot family rather than a parameter
  /// on it: [AudioPlayersSoundPlayer] runs this on its own player, so a
  /// message chime arriving mid-ring plays over it rather than cutting it
  /// off, and stopping the ring later never touches an unrelated one-shot.
  Future<void> loop(NotificationSound sound);

  /// Stops whatever [loop] started. A no-op if nothing is looping.
  Future<void> stopLoop();

  Future<void> dispose();
}

/// Plays over `audioplayers`, configured so a chime can never take the
/// session, route, or focus a live call already holds - see the library
/// doc comment above for why that is this package's whole reason to exist.
class AudioPlayersSoundPlayer implements SoundPlayer {
  AudioPlayersSoundPlayer({this.afterPlay, bool Function()? inCall})
    : inCall = inCall ?? (() => false);

  /// Whether a call holds the audio session right now.
  final bool Function() inCall;

  /// Runs once a sound has started, to route its stream to the chosen speaker.
  final Future<void> Function()? afterPlay;

  /// Both players are built on first use: constructing one on Linux throws a
  /// native exception, uncatchable from Dart, when GStreamer's playbin is missing.
  AudioPlayer? _createdPlayer;
  AudioPlayer get _player => _createdPlayer ??= AudioPlayer();

  /// Its own player, never the shared [_player]: see [SoundPlayer.loop]'s
  /// own doc for why a looping ring and a one-shot chime must not share one.
  final _loopPlayer = ReleasablePlayer<AudioPlayer>(
    AudioPlayer.new,
    (player) => player.dispose(),
  );

  /// Backlog #134: the wav family is already level with itself (see
  /// `assets/audio/synth.py`'s `NOTIFICATION_LUFS`), but `audioplayers` defaults a
  /// player to full scale on top of that, so every chime still played at the
  /// device's whole notification volume with no headroom of its own. This is
  /// the app's own attenuation on top of that OS level, not a replacement
  /// for it - the "grab system levels" half of the ask is what the OS
  /// volume control already does, since `AudioContext` above asks for no
  /// audio focus and never touches the system volume itself.
  ///
  /// Public rather than `@visibleForTesting`: `scene_sound_player.dart` plays
  /// a module's sound at this identical volume too, so a module's cue is
  /// never louder than the app's own chimes.
  static const double playbackVolume = 0.6;

  /// iOS `.ambient`: the platform's own category for a short sound that must
  /// never interrupt or duck whatever else is playing, which is why it is
  /// used here rather than `.playback` with `mixWithOthers` added by hand -
  /// `AudioContextIOS`'s own asserts (read from source, not assumed) refuse
  /// `mixWithOthers` as an explicit option on `.ambient` because the category
  /// already implies it. Android asks for no audio focus at all
  /// (`AndroidAudioFocus.none`), the closest equivalent: a player that never
  /// contends for focus can never be the reason a call's audio pauses.
  ///
  /// Public (not `_context`) because `scene_sound_player.dart` plays a
  /// module's sound under this identical configuration - a module's cue
  /// must be exactly as unable to steal a call's audio as a chime is.
  static final sharedAmbientContext = soundAudioContext(ios: false);

  /// The context for this moment: in a call on iOS it matches the call's session.
  AudioContext get _context => soundAudioContext(inCall: inCall());

  @override
  Future<void> play(NotificationSound sound) async {
    // Stopped first, or two overlapping `play()` calls would race.
    await _player.stop();
    await playQuietly(
      () => _player.play(
        AssetSource(sound._playerPath),
        volume: playbackVolume,
        ctx: _context,
      ),
    );
    unawaited(afterPlay?.call());
  }

  @override
  Future<void> loop(NotificationSound sound) async {
    final player = _loopPlayer.current;
    await player.stop();
    await player.setReleaseMode(ReleaseMode.loop);
    await playQuietly(
      () => player.play(
        AssetSource(sound._playerPath),
        volume: playbackVolume,
        ctx: _context,
      ),
    );
    unawaited(afterPlay?.call());
  }

  @override
  Future<void> stopLoop() => _loopPlayer.release();

  @override
  Future<void> dispose() async {
    await _createdPlayer?.dispose();
    await _loopPlayer.release();
  }
}
