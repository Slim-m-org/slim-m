// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hides a video renderer until it has actually painted something.
///
/// `livekit_client`'s `VideoTrackRenderer` attaches its platform texture to
/// the track's stream the moment the renderer initializes, not when a frame
/// has decoded: flutter_webrtc's own `RTCVideoRenderer.renderVideo` (the
/// getter its `RTCVideoView` uses to decide whether to paint the texture or
/// its `placeholderBuilder`) is `textureId != null && srcObject != null`,
/// true as soon as the stream attaches. Until the decoder writes a first
/// frame into that texture, whatever GPU memory it already held shows
/// through - stale attachments, emoji, fragments of other UI - which is
/// exactly what the owner saw appear in a screen-share tile before the real
/// picture arrived.
///
/// The fix needs a signal it never exposes: the platform
/// renderer's own `onFirstFrameRendered` callback, which native code only
/// calls once a real decoded frame has painted. Reaching it means owning the
/// `RTCVideoRenderer` ourselves and handing it in as `cachedRenderer`, since
/// the widget's own renderer field is private.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Whether a video renderer has painted its first real frame.
///
/// Starts false and latches true forever once [markFirstFrame] runs: a
/// renderer that has ever shown real content has nothing left to hide, even
/// if the stream underneath it later drops a frame or stalls.
class FirstFrameTracker extends ChangeNotifier {
  bool _hasFrame = false;

  bool get hasFrame => _hasFrame;

  /// Wires this tracker to the platform's own first-frame signal. Called
  /// once, on a freshly created [renderer] - see [OwnedVideoRenderer].
  void attach(rtc.RTCVideoRenderer renderer, {bool web = kIsWeb}) {
    renderer.onFirstFrameRendered = markFirstFrame;
    if (web) watchVideoSize(renderer);
  }

  /// The web renderer declares `onFirstFrameRendered` but never calls it, so
  /// the gate never opened there; its value takes the video's size once the
  /// element has a frame to play, which is the same moment.
  void watchVideoSize(ValueListenable<rtc.RTCVideoValue> value) {
    void check() {
      if (value.value.width > 0 && value.value.height > 0) markFirstFrame();
    }

    value.addListener(check);
    check();
  }

  /// The single entry point [attach] wires up; also callable directly by
  /// tests, which have no native renderer to fire the real callback.
  void markFirstFrame() {
    if (_hasFrame) return;
    _hasFrame = true;
    notifyListeners();
  }
}

/// A renderer this object created, initialized, and is responsible for
/// disposing - never `VideoTrackRenderer`'s own, which is private.
///
/// Passed to `VideoTrackRenderer` as its `cachedRenderer` (with
/// `autoDisposeRenderer: false`, per that parameter's own contract: "belongs
/// to the caller"), this is what lets [tracker] hear a frame arrive.
class OwnedVideoRenderer {
  final FirstFrameTracker tracker = FirstFrameTracker();
  rtc.RTCVideoRenderer? _renderer;

  rtc.RTCVideoRenderer? get renderer => _renderer;

  Future<void> initialize() async {
    final renderer = rtc.RTCVideoRenderer();
    await renderer.initialize();
    tracker.attach(renderer);
    _renderer = renderer;
  }

  Future<void> dispose() async {
    final renderer = _renderer;
    _renderer = null;
    await renderer?.dispose();
  }
}

/// Builds a renderer's video view under a key unique to [owned].
///
/// `VideoTrackRenderer` reads `cachedRenderer` once, in `initState`, so a state
/// reused for the next track keeps drawing into the renderer already disposed.
class OwnedRendererView extends StatelessWidget {
  const OwnedRendererView({
    super.key,
    required this.owned,
    required this.builder,
  });

  final OwnedVideoRenderer owned;
  final Widget Function(rtc.RTCVideoRenderer? renderer) builder;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
        key: ObjectKey(owned),
        child: builder(owned.renderer),
      );
}

/// Shows [placeholder] over [child] until [tracker] reports a first frame,
/// then shows [child] alone from then on.
///
/// [child] stays mounted underneath the placeholder the whole time rather
/// than being built only after the flip: it is what owns the renderer that
/// [tracker] is listening to, so it has to already be attached to receive
/// the very callback this widget is waiting for.
class FirstFrameReveal extends StatefulWidget {
  const FirstFrameReveal({
    super.key,
    required this.tracker,
    required this.placeholder,
    required this.child,
  });

  final FirstFrameTracker tracker;
  final Widget placeholder;
  final Widget child;

  @override
  State<FirstFrameReveal> createState() => _FirstFrameRevealState();
}

class _FirstFrameRevealState extends State<FirstFrameReveal> {
  @override
  void initState() {
    super.initState();
    widget.tracker.addListener(_onFrameChanged);
  }

  void _onFrameChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant FirstFrameReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tracker != oldWidget.tracker) {
      oldWidget.tracker.removeListener(_onFrameChanged);
      widget.tracker.addListener(_onFrameChanged);
    }
  }

  @override
  void dispose() {
    widget.tracker.removeListener(_onFrameChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tracker.hasFrame) return widget.child;
    return Stack(
        fit: StackFit.expand, children: [widget.child, widget.placeholder]);
  }
}
