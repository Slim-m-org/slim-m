// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop player drawn by Flutter: its texture, sized to this box and
/// clipped, scrolled and covered like any other widget, with the pointer
/// forwarded to the page so YouTube's own controls work. While a page
/// covers it (TickerMode off) it counts as hidden, and with no view left
/// the video pauses.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/desktop_video.dart';
import '../providers/desktop_video_player.dart';
import 'desktop_video_fullscreen.dart';

class DesktopVideoView extends ConsumerStatefulWidget {
  const DesktopVideoView({
    super.key,
    required this.player,
    this.fullscreenRoute = false,
  });

  /// The texture the player draws into.
  static const textureKey = Key('desktop-video-texture');

  final DesktopVideoPlayer player;

  /// True for the view inside the fullscreen route, which never opens
  /// another one.
  final bool fullscreenRoute;

  @override
  ConsumerState<DesktopVideoView> createState() => _DesktopVideoViewState();
}

class _DesktopVideoViewState extends ConsumerState<DesktopVideoView> {
  late final DesktopVideoController _controller;
  ValueListenable<TickerModeData>? _tickerMode;
  bool _shown = false;
  Size? _size;
  double _ratio = 1;
  (Size, double)? _sent;
  bool _fullscreenPushed = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(desktopVideoProvider.notifier);
    _controller.frontView.addListener(_queueSend);
    _controller.fullscreen.addListener(_onFullscreen);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ratio = MediaQuery.devicePixelRatioOf(context);
    _queueSend();
    _tickerMode?.removeListener(_syncShown);
    _tickerMode = TickerMode.getValuesNotifier(context)
      ..addListener(_syncShown);
    _syncShown();
  }

  void _syncShown() {
    final shown = _tickerMode?.value.enabled ?? true;
    if (shown == _shown) return;
    _shown = shown;
    if (shown) {
      _sent = null;
      _controller.showIn(this);
      _sendSize();
    } else {
      _controller.hideFrom(this);
    }
  }

  void _onLayout(Size size) {
    if (size == _size) return;
    _size = size;
    _queueSend();
  }

  /// After the frame, since the front can change while views unmount.
  void _queueSend() {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => _sendSize())
      ..ensureVisualUpdate();
  }

  void _sendSize() {
    final size = _size;
    if (!mounted || size == null || size.isEmpty) return;
    // Another view sized the page meanwhile, so this one resends when it is in front again.
    if (!identical(_controller.frontView.value, this)) {
      _sent = null;
      return;
    }
    if (_sent == (size, _ratio)) return;
    _sent = (size, _ratio);
    unawaited(widget.player.resize(size, _ratio));
  }

  void _onFullscreen() {
    if (widget.fullscreenRoute || !mounted || _fullscreenPushed) return;
    if (!_controller.fullscreen.value) return;
    if (!identical(_controller.frontView.value, this)) return;
    _fullscreenPushed = true;
    unawaited(
      showDesktopVideoFullscreen(
        context,
        widget.player,
      ).whenComplete(() => _fullscreenPushed = false),
    );
  }

  void _forward(VideoPointerKind kind, Offset position) =>
      unawaited(widget.player.pointer(kind, position));

  @override
  void dispose() {
    _tickerMode?.removeListener(_syncShown);
    _controller.frontView.removeListener(_queueSend);
    _controller.fullscreen.removeListener(_onFullscreen);
    if (_shown) _controller.hideFrom(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (e) => _forward(VideoPointerKind.enter, e.localPosition),
      onExit: (e) => _forward(VideoPointerKind.leave, e.localPosition),
      child: Listener(
        onPointerHover: (e) => _forward(VideoPointerKind.move, e.localPosition),
        onPointerMove: (e) {
          if (e.buttons & kPrimaryButton != 0) {
            _forward(VideoPointerKind.move, e.localPosition);
          }
        },
        onPointerDown: (e) {
          if (e.buttons & kPrimaryButton != 0) {
            _forward(VideoPointerKind.down, e.localPosition);
          }
        },
        onPointerUp: (e) => _forward(VideoPointerKind.up, e.localPosition),
        child: _SizeReporter(
          onLayout: _onLayout,
          child: ColoredBox(
            color: const Color(0xFF000000),
            child: ValueListenableBuilder<int?>(
              valueListenable: widget.player.texture,
              builder: (_, id, _) => id == null
                  ? const SizedBox.expand()
                  : Texture(
                      key: DesktopVideoView.textureKey,
                      textureId: id,
                      filterQuality: FilterQuality.medium,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reports the size layout gave its child, which the page is then sized to.
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onLayout, super.child});

  final ValueChanged<Size> onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onLayout);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSizeReporter renderObject,
  ) => renderObject.onLayout = onLayout;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onLayout);

  ValueChanged<Size> onLayout;

  @override
  void performLayout() {
    super.performLayout();
    onLayout(size);
  }
}
