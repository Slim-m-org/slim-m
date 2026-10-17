// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Jumping to a message: the one entry point every tappable result (search,
/// pins, the command palette) calls, the row wrapper that scrolls to and
/// flashes the arrival, and the notice for when it cannot be reached.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/message_jump.dart';
import '../providers/message_search.dart' show ProviderReader;
import '../../../routing/routes.dart';
import '../../../widgets/app_snackbar.dart';

/// Switches to [channelId] if [currentChannelId] says it is not already
/// open, then asks [MessageJumpController] to bring [messageId] into view
/// and flash it there - paging backwards first if it is not loaded yet.
/// Routes with `openChat` so a voice channel's chat opens without joining
/// its call.
///
/// Takes a [GoRouter] and a [ProviderReader] rather than a [BuildContext]:
/// every call site either already has both to hand or pops a sheet, a dialog
/// or a menu on its way here, and a context read after that pop is not safe
/// to trust (see `channel_message_actions.dart`'s `reportMessage` for the
/// same shape). The jump itself is never awaited by the caller: it runs in
/// the background so a tap closes whatever it was made from immediately
/// rather than waiting on however many pages the jump takes.
void jumpToMessage(
  GoRouter router,
  ProviderReader read, {
  required String? currentChannelId,
  required String channelId,
  required String messageId,
}) {
  if (currentChannelId != channelId) {
    router.go(Routes.channel(channelId, openChat: true));
  }
  unawaited(read(messageJumpProvider.notifier).jumpTo(channelId, messageId));
}

/// What the channel screen needs from [messageJumpProvider] in one call:
/// watches it for [channelId]'s own arrival (if any, for
/// `MessageTranscript`'s highlight params) and listens for a refusal to show
/// a plain notice for rather than a silent no-op.
({String messageId, int token})? watchMessageJump(
  WidgetRef ref,
  BuildContext context,
  String channelId,
) {
  final arrival = jumpArrivalFor(ref.watch(messageJumpProvider), channelId);
  ref.listen(messageJumpProvider, (_, next) {
    if (next case MessageJumpUnreachable(
      channelId: final c,
      :final token,
    ) when c == channelId) {
      showAppSnackbar(context, 'Could not find that message.');
      ref.read(messageJumpProvider.notifier).dismissUnreachable(token);
    }
  });
  return arrival;
}

/// Wraps the one row a jump has landed on: scrolls it into view, then flashes
/// a tinted background that fades out - Discord's own arrival cue, held flat
/// and removed rather than animated under reduce motion.
///
/// Keyed by the jump's token at the call site, matching `MessageEntrance`'s
/// own shape: a fresh token mounts a fresh instance, and a rebuild that keeps
/// the same token reuses the one already running rather than restarting it.
class MessageJumpHighlight extends StatefulWidget {
  const MessageJumpHighlight({
    super.key,
    required this.child,
    required this.onArrived,
  });

  final Widget child;

  /// Called once the scroll has landed, so the caller can tell the jump
  /// controller this arrival has been handled.
  final VoidCallback onArrived;

  @override
  State<MessageJumpHighlight> createState() => _MessageJumpHighlightState();
}

class _MessageJumpHighlightState extends State<MessageJumpHighlight> {
  bool _lit = true;
  bool _started = false;

  /// How long the tint stays fully lit before easing back out.
  static const _hold = Duration(milliseconds: 700);

  /// Under reduce motion there is no ease-out at all, so the flat tint is
  /// held for less time before it is simply removed.
  static const _reducedHold = Duration(milliseconds: 500);

  static const _fadeOut = Duration(milliseconds: 2000);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _arrive());
  }

  Future<void> _arrive() async {
    if (!mounted) return;
    await Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: AppMotion.reduced(context, AppMotion.slow),
      curve: AppMotion.entrance,
    );
    if (!mounted) return;
    final reduced = AppMotion.isReduced(context);
    await Future<void>.delayed(reduced ? _reducedHold : _hold);
    if (mounted) setState(() => _lit = false);
    // Let the fade actually play first, or consuming this now unmounts the wrapper mid-fade rather than letting the tint finish.
    if (!reduced) await Future<void>.delayed(_fadeOut);
    widget.onArrived();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AnimatedContainer(
      duration: AppMotion.reduced(context, _fadeOut),
      curve: AppMotion.exit,
      color: _lit
          ? tokens.accentSoft.withValues(alpha: 0.35)
          : Colors.transparent,
      child: widget.child,
    );
  }
}
