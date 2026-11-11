// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens and closes one pop-out OS window per requested feed as each comes and goes.
///
/// Closing a window clears that feed's request and never touches the call or the
/// other windows: only a window's own leave button ends the call. A feed that
/// stops closes its window; a call that ends or an app lock closes them all.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart' show VideoShapeScope;

import '../../../desktop/popout/popout_windowing.dart';
import '../providers/call_mini_player.dart';
import '../providers/picture_in_picture.dart' show pictureInPictureTileKey;
import '../providers/popout_window.dart';
import '../providers/voice_controller.dart';
import 'popout_window_view.dart';

const _windowSize = Size(640, 400);

class PopOutHost extends ConsumerStatefulWidget {
  const PopOutHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PopOutHost> createState() => _PopOutHostState();
}

class _OpenWindow {
  _OpenWindow(this.feed, this.handle, this.releaseEnlarged);

  final MiniPlayerFeed feed;
  final PopOutWindowHandle handle;
  final VoidCallback releaseEnlarged;

  void dispose() {
    releaseEnlarged();
    handle.destroy();
  }
}

class _PopOutHostState extends ConsumerState<PopOutHost> {
  final _windows = <String, _OpenWindow>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync(ref.read(popOutLiveFeedsProvider));
    });
  }

  @override
  void dispose() {
    for (final window in _windows.values) {
      window.dispose();
    }
    super.dispose();
  }

  void _close(MiniPlayerFeed feed) =>
      ref.read(popOutFeedsProvider.notifier).close(feed);

  /// A popped-out feed has its own window, so Data saver must not cap it.
  VoidCallback _holdSharp(MiniPlayerFeed feed) => ref
      .read(voiceControllerProvider.notifier)
      .video
      .holdEnlargedVideo(pictureInPictureTileKey(feed));

  _OpenWindow? _open(MiniPlayerFeed feed) {
    final factory = ref.read(popOutWindowFactoryProvider);
    if (factory == null) return null;
    final handle = factory(
      title: popOutWindowTitle,
      size: _windowSize,
      decorated: false,
      onCloseRequested: () => _close(feed),
    );
    _keepAbove(handle);
    return _OpenWindow(feed, handle, _holdSharp(feed));
  }

  void _sync(List<MiniPlayerFeed> live) {
    final wanted = {
      for (final feed in live) pictureInPictureTileKey(feed): feed,
    };
    for (final key in _windows.keys.toList()) {
      if (!wanted.containsKey(key)) _windows.remove(key)!.dispose();
    }
    for (final MapEntry(:key, value: feed) in wanted.entries) {
      if (_windows.containsKey(key)) continue;
      final window = _open(feed);
      if (window != null) _windows[key] = window;
    }
    ref.read(popOutFeedsProvider.notifier).keepOnly(live);
    setState(() {});
  }

  /// Asked once the window has drawn, since a window manager only finds a mapped window, and once more in case it was slow to map.
  void _keepAbove(PopOutWindowHandle handle) {
    for (final wait in const [
      Duration(milliseconds: 300),
      Duration(seconds: 1),
    ]) {
      Timer(wait, () {
        if (mounted &&
            _windows.values.any((w) => identical(w.handle, handle))) {
          unawaited(handle.keepAbove());
        }
      });
    }
  }

  Widget _view(String key, _OpenWindow window) {
    final handle = window.handle;
    return KeyedSubtree(
      key: ValueKey(key),
      child: handle.host(
        VideoShapeScope(
          onShape: handle.fitAspect,
          child: PopOutWindowView(
            feed: window.feed,
            frame: handle.drawsOwnFrame
                ? PopOutFrame(
                    onMoveStart: handle.beginMove,
                    onResizeStart: handle.beginResize,
                    onClose: () => _close(window.feed),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(popOutLiveFeedsProvider, (_, next) => _sync(next));
    return ViewAnchor(
      view: _windows.isEmpty
          ? null
          : ViewCollection(
              views: [
                for (final MapEntry(:key, value: window) in _windows.entries)
                  _view(key, window),
              ],
            ),
      child: widget.child,
    );
  }
}
