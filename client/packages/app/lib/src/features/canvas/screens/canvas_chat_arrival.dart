// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens a canvas channel's chat on arrival when the route asked to read it, such as a tapped message notification.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/canvas_channel_chat_open.dart';
import 'canvas_chat_toggle.dart';

/// Shows [child], the board, and opens the chat beside it or over it, by what the width holds.
class CanvasChatArrival extends ConsumerStatefulWidget {
  const CanvasChatArrival({
    super.key,
    required this.channelId,
    required this.openChat,
    required this.child,
  });

  final String channelId;
  final bool openChat;
  final Widget child;

  @override
  ConsumerState<CanvasChatArrival> createState() => _CanvasChatArrivalState();
}

class _CanvasChatArrivalState extends ConsumerState<CanvasChatArrival> {
  @override
  void initState() {
    super.initState();
    _arrive();
  }

  @override
  void didUpdateWidget(covariant CanvasChatArrival oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.openChat && widget.openChat) _arrive();
  }

  void _arrive() {
    if (!widget.openChat) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (canvasChatDocks(context)) {
        ref
                .read(canvasChannelChatOpenProvider(widget.channelId).notifier)
                .state =
            true;
      } else {
        unawaited(showCanvasChatSheet(context, widget.channelId));
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
