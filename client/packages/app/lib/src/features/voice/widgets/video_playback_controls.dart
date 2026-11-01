// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The chrome an attachment video draws over `package:media_kit`'s bare
/// texture - a scrubber, play/pause, elapsed/remaining time, mute, and the
/// full screen toggle - plus the two gestures the owner asked for by name: a
/// single tap shows or hides this chrome, and a double tap enters (or
/// leaves) full screen.
///
/// [Video] itself renders `AdaptiveVideoControls` by default, which draws
/// Material's own transport bar; both call sites that build a [Video] here
/// pass `controls: null` and let this widget be the only chrome, so
/// playback always reads as this app rather than a generic player.
///
/// Double-tap-to-seek is the other convention video players use for a
/// double tap; this app picked double-tap-to-fullscreen instead; because a
/// message attachment is a short clip in a small inline frame, not a feed
/// scrubbed by seeking, and the owner asked for the fullscreen gesture by
/// name. Seeking is still reachable, through the scrubber this widget draws.
///
/// The single tap is a plain [GestureDetector.onTap], not paired with
/// [GestureDetector.onDoubleTap] on the same recognizer: Flutter only holds
/// a tap for [kDoubleTapTimeout] when a widget registers both, so pairing
/// them would make every single tap lag behind a wait to see if a second one
/// is coming - exactly what the owner asked to avoid. Instead the double tap
/// is detected by hand, with a cancellable [Timer] that arms on the first
/// tap and disarms itself after [kDoubleTapTimeout], so a single tap always
/// resolves immediately and a second one inside that window reads as the
/// double tap on top of it rather than instead of it. A timer rather than a
/// [DateTime] timestamp diff for the same reason every duration in this
/// widget is a [Timer]: only a [Timer] is virtualized under a widget test's
/// fake clock, so the gesture is exercised the same way in a test as live.
///
/// The fullscreen gesture and the scrubber's own drag are both touch-shaped
/// affordances; per `desktop-vs-mobile.md`'s core rule ("layout responds to
/// window width, never platform") the double tap only acts on
/// [AppTouchTargets.of] rather than every pointer kind, since a mouse user
/// already has the same fullscreen toggle as a button in this same bar.
///
/// Under a pointer the bar follows the pointer: it starts hidden, shows on
/// hover, and hides when the pointer leaves or the window loses focus, so a
/// column of paused clips does not each carry a permanent transport bar. A
/// hidden, paused clip shows a single centered play button instead.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:slimm_design_system/design_system.dart';

import 'video_controls_bar.dart';

/// How long an idle, playing video keeps its controls up before fading them.
const Duration kVideoControlsAutoHide = Duration(seconds: 3);

/// Renders [child] (a [Video] or a loading placeholder) with this app's own
/// playback chrome layered on top.
///
/// [player] is read directly rather than through a controller object of this
/// widget's own: every transport action (play, seek, mute) is already a
/// method on `package:media_kit`'s [Player], and duplicating that surface
/// behind a second API would only be one more place for the two to drift.
///
/// The bar always draws in this system's dark theme, matching every other
/// full-bleed video surface (`fullscreen_image_viewer.dart`,
/// `fullscreen_video_overlay.dart`): it sits on top of a video, not the
/// app's own background, so it has to stay legible whichever theme the rest
/// of the app is currently in.
class VideoPlaybackControls extends StatefulWidget {
  const VideoPlaybackControls({
    super.key,
    required this.player,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    required this.child,
    this.onSave,
    this.saving = false,
    this.autoHideDelay = kVideoControlsAutoHide,
  });

  final Player player;

  /// Whether this bar is drawn in the full screen route or the inline frame.
  /// Same widget either way; only the fullscreen-toggle icon and the safe
  /// area handling read it.
  final bool isFullscreen;

  final VoidCallback onToggleFullscreen;
  final Widget child;

  /// Saves the clip; null leaves the save button out of the bar.
  final VoidCallback? onSave;

  /// Whether a save of this clip is already running.
  final bool saving;

  /// [kVideoControlsAutoHide], except in a test, which shrinks it so a
  /// widget test never has to sit through a real three-second wait.
  final Duration autoHideDelay;

  @override
  State<VideoPlaybackControls> createState() => _VideoPlaybackControlsState();
}

class _VideoPlaybackControlsState extends State<VideoPlaybackControls>
    with WidgetsBindingObserver {
  bool _visible = true;
  bool _visibilityChosen = false;

  /// The level unmuting returns to, so mute then unmute keeps a chosen volume.
  double _unmutedVolume = 100;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 100;

  /// The slider's displayed value while a scrub is in flight, overriding the
  /// stream `position` above: that stream lags a live seek by a frame or
  /// two, and without this override the thumb would snap back to the old
  /// position and then forward again once it catches up.
  double? _scrubMs;

  /// Armed by the first tap of a possible double tap; disarmed either by a
  /// second tap landing before it fires, or by itself once
  /// [kDoubleTapTimeout] passes with no second tap.
  Timer? _doubleTapTimer;
  bool _awaitingSecondTap = false;

  Timer? _hideTimer;
  Timer? _scrubClearTimer;

  late final StreamSubscription<bool> _playingSub;
  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<Duration> _durationSub;
  late final StreamSubscription<double> _volumeSub;

  @override
  void initState() {
    super.initState();
    final state = widget.player.state;
    _playing = state.playing;
    _position = state.position;
    _duration = state.duration;
    _volume = state.volume;
    if (_volume > 0) _unmutedVolume = _volume;
    WidgetsBinding.instance.addObserver(this);
    _playingSub = widget.player.stream.playing.listen((value) {
      if (!mounted) return;
      setState(() => _playing = value);
      _syncAutoHide();
    });
    _positionSub = widget.player.stream.position.listen((value) {
      if (mounted) setState(() => _position = value);
    });
    _durationSub = widget.player.stream.duration.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    _volumeSub = widget.player.stream.volume.listen((value) {
      if (mounted) setState(() => _volume = value);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Touch starts with the bar up, since there is no hover to reveal it.
    if (!_visibilityChosen) {
      _visibilityChosen = true;
      _visible = AppTouchTargets.of(context);
      _syncAutoHide();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _visible && mounted) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _scrubClearTimer?.cancel();
    _doubleTapTimer?.cancel();
    unawaited(_playingSub.cancel());
    unawaited(_positionSub.cancel());
    unawaited(_durationSub.cancel());
    unawaited(_volumeSub.cancel());
    super.dispose();
  }

  /// A playing video with the bar showing gets a countdown to hide it again;
  /// paused or already-hidden never schedules one.
  void _syncAutoHide() {
    _hideTimer?.cancel();
    if (_playing && _visible) {
      _hideTimer = Timer(widget.autoHideDelay, () {
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  void _showControls() {
    if (!_visible) setState(() => _visible = true);
    _syncAutoHide();
  }

  void _onExit() {
    // A scrub drag can leave the frame; hiding mid-drag would drop the thumb.
    if (_scrubMs != null) return;
    _hideTimer?.cancel();
    setState(() => _visible = false);
  }

  void _handleTap() {
    if (_awaitingSecondTap) {
      _doubleTapTimer?.cancel();
      _awaitingSecondTap = false;
      if (AppTouchTargets.of(context)) {
        widget.onToggleFullscreen();
      }
      return;
    }
    _awaitingSecondTap = true;
    _doubleTapTimer = Timer(
      kDoubleTapTimeout,
      () => _awaitingSecondTap = false,
    );
    if (_visible) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    } else {
      _showControls();
    }
  }

  void _togglePlay() {
    widget.player.playOrPause();
    _showControls();
  }

  void _scrub(double milliseconds) {
    widget.player.seek(Duration(milliseconds: milliseconds.round()));
    setState(() => _scrubMs = milliseconds);
    _scrubClearTimer?.cancel();
    _scrubClearTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _scrubMs = null);
    });
    _showControls();
  }

  void _toggleMute() {
    if (_volume > 0) _unmutedVolume = _volume;
    widget.player.setVolume(_volume > 0 ? 0 : _unmutedVolume);
    _showControls();
  }

  void _setVolume(double value) {
    if (value > 0) _unmutedVolume = value;
    widget.player.setVolume(value);
    setState(() => _volume = value);
    _showControls();
  }

  @override
  Widget build(BuildContext context) {
    final fade = AppMotion.reduced(context, AppMotion.fast);
    return MouseRegion(
      onEnter: (_) => _showControls(),
      onHover: (_) => _showControls(),
      onExit: (_) => _onExit(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleTap,
            ),
          ),
          // Forced dark: see the class doc for why this ignores the app theme.
          Theme(
            data: buildTheme(Brightness.dark, AppTokens.dark),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!_visible && !_playing)
                  Center(child: _CenterPlayButton(onPressed: _togglePlay)),
                AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: fade,
                  curve: AppMotion.entrance,
                  child: IgnorePointer(
                    ignoring: !_visible,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: VideoControlsBar(
                        playing: _playing,
                        position: _position,
                        duration: _duration,
                        scrubMs: _scrubMs,
                        volume: _volume,
                        isFullscreen: widget.isFullscreen,
                        saving: widget.saving,
                        onPlayPause: _togglePlay,
                        onScrub: _scrub,
                        onToggleMute: _toggleMute,
                        onVolume: _setVolume,
                        onToggleFullscreen: widget.onToggleFullscreen,
                        onSave: widget.onSave,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The one control a hidden, paused clip keeps, so it still reads as a video.
class _CenterPlayButton extends StatelessWidget {
  const _CenterPlayButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      child: AppIconButton(
        icon: AppIcons.play,
        semanticLabel: 'Play',
        variant: AppIconButtonVariant.ghost,
        onPressed: onPressed,
      ),
    );
  }
}
