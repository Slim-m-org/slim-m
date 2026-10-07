// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_pane.dart';

/// Entering and leaving fullscreen, and the tool swap that rides with it.
///
/// A `part of` rather than plain methods for the same reason
/// `_CanvasPaneHelpers` and `_CanvasPaneGestures` already are:
/// `canvas_pane.dart` has no room under the file budget, and this needs
/// `_CanvasPaneState`'s own fields. `setState` and `mounted` are `@protected`
/// on `State`, so nothing here calls either directly - `_refresh` is the
/// bridge that already exists for exactly that.
extension _CanvasPaneFullscreen on _CanvasPaneState {
  bool get _fullscreen =>
      ref.watch(canvasFullscreenProvider) == widget.channelId;

  /// Flips fullscreen for this channel, disarming the pen on the way in and
  /// putting the previous tool back on the way out.
  ///
  /// The tool swap is what makes a viewing mode safe to offer at all: with
  /// the tool strip folded away, a one-finger drag would otherwise still draw
  /// with whatever was armed, because `CanvasSurface` pans and zooms on two
  /// pointers only. [CanvasTool.pan] places nothing, and on empty space it
  /// selects nothing either, so a drag through open canvas does what a person
  /// entering a "just show me the content" mode expects it to.
  void _toggleFullscreen() {
    final notifier = ref.read(canvasFullscreenProvider.notifier);
    if (_fullscreen) {
      notifier.state = null;
      // Whatever was armed on the way in, or the default tool if this pane opened straight into fullscreen and has nothing of its own to restore.
      _refresh(() => _tool = _toolBeforeFullscreen ?? _defaultTool);
      _toolBeforeFullscreen = null;
      return;
    }
    notifier.state = widget.channelId;
    _refresh(() {
      _toolBeforeFullscreen = _tool;
      _tool = CanvasTool.pan;
    });
  }

  /// A pane that mounts while its channel is still fullscreen (the provider
  /// outlives it) gets the same disarmed pen [_toggleFullscreen] gives one
  /// that entered it, and the same tool to restore on the way out.
  void _disarmIfAlreadyFullscreen() {
    if (ref.read(canvasFullscreenProvider) != widget.channelId) return;
    _toolBeforeFullscreen = _tool;
    _tool = CanvasTool.pan;
  }

  /// Closes the canvas outright. Clears fullscreen in the same motion, or a
  /// channel reopened later would come back with its chrome already dropped
  /// and no memory of why.
  void _closeCanvas() {
    ref.read(canvasFullscreenProvider.notifier).state = null;
    ref.read(canvasOpenProvider.notifier).state = null;
  }

  /// Hanging up closes the canvas with the call. The owner hung up from the
  /// fullscreen canvas and was left on an empty grid with one button; closing
  /// it by hand minutes later remounted `VoiceScreen` past
  /// `VoiceState.rejoinGuardWindow`, which read as a fresh arrival and joined
  /// the call straight back. Closing here, in the same motion as the leave,
  /// lands inside that window, so the voice screen shows the recap instead.
  /// Only the call *ending* counts - a canvas opened outside any call never
  /// sees this transition and stays put.
  void _closeWhenCallEnds(VoiceFlags? previous, VoiceFlags next) {
    if (previous?.channelId != widget.channelId) return;
    if (next.channelId != null) return;
    if (ref.read(canvasOpenProvider) != widget.channelId) return;
    _closeCanvas();
  }
}
