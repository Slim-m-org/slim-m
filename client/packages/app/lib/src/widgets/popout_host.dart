// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens and closes the pop-out OS window as the requested feed comes and goes.
///
/// Closing the window clears the request and never touches the call: only the
/// window's own leave button does that. A feed that stops, or a call that ends,
/// closes the window behind it.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/popout/popout_windowing.dart';
import '../providers/call_mini_player.dart';
import '../providers/popout_window.dart';
import 'popout_window_view.dart';

const _windowSize = Size(640, 400);

class PopOutHost extends ConsumerStatefulWidget {
  const PopOutHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PopOutHost> createState() => _PopOutHostState();
}

class _PopOutHostState extends ConsumerState<PopOutHost> {
  PopOutWindowHandle? _handle;
  MiniPlayerFeed? _feed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync(ref.read(popOutLiveFeedProvider));
    });
  }

  @override
  void dispose() {
    _handle?.destroy();
    super.dispose();
  }

  void _close() => ref.read(popOutFeedProvider.notifier).state = null;

  void _sync(MiniPlayerFeed? next) {
    if (next == null) {
      ref.read(popOutFeedProvider.notifier).state = null;
      if (_handle == null) return;
      _handle!.destroy();
      setState(() {
        _handle = null;
        _feed = null;
      });
      return;
    }
    if (_handle == null) {
      final factory = ref.read(popOutWindowFactoryProvider);
      if (factory == null) return;
      final handle = factory(
        title: 'slim-m',
        size: _windowSize,
        decorated: false,
        onCloseRequested: _close,
      );
      setState(() => _handle = handle);
    }
    setState(() => _feed = next);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(popOutLiveFeedProvider, (_, next) => _sync(next));
    final handle = _handle;
    final feed = _feed;
    return ViewAnchor(
      view: handle == null || feed == null
          ? null
          : handle.host(
              PopOutWindowView(
                feed: feed,
                frame: PopOutFrame(
                  onMoveStart: handle.beginMove,
                  onResizeStart: handle.beginResize,
                  onClose: _close,
                ),
              ),
            ),
      child: widget.child,
    );
  }
}
