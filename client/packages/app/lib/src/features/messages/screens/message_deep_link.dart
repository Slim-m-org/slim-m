// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The page behind `Routes.message`: the channel, with a jump to one message
/// started as soon as it is on screen.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/message_jump.dart';
import '../../../screens/home_shell.dart' show ConversationPane;

/// Reads rather than joins: a link is not consent to enter a voice call, the
/// same rule `jumpToMessage` applies with `openChat`.
class MessageDeepLink extends ConsumerStatefulWidget {
  const MessageDeepLink({
    super.key,
    required this.channelId,
    required this.messageId,
  });

  final String channelId;
  final String messageId;

  @override
  ConsumerState<MessageDeepLink> createState() => _MessageDeepLinkState();
}

class _MessageDeepLinkState extends ConsumerState<MessageDeepLink> {
  @override
  void initState() {
    super.initState();
    _jump();
  }

  @override
  void didUpdateWidget(MessageDeepLink old) {
    super.didUpdateWidget(old);
    final moved =
        old.channelId != widget.channelId || old.messageId != widget.messageId;
    if (moved) _jump();
  }

  void _jump() {
    final channelId = widget.channelId;
    final messageId = widget.messageId;
    // After the frame, so the jump never writes provider state during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref.read(messageJumpProvider.notifier).jumpTo(channelId, messageId),
      );
    });
  }

  @override
  Widget build(BuildContext context) =>
      ConversationPane(channelId: widget.channelId, openChat: true);
}
