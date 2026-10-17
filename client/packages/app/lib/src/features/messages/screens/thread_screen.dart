// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The thread panel: a message's sub-channel, opened by "Reply in thread".
///
/// It reuses [ChannelScreen] and keeps its own header to back and title; why
/// each other control is left out, and why it is told it is a thread rather
/// than asking the store, is in docs/decisions/0005-threads.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../channels/providers/threads.dart';
import '../../../routing/close_screen.dart';
import '../../../routing/routes.dart';
import '../../channels/widgets/compact_channel_app_bar.dart'
    show ChannelSearchAction;
import '../../channels/screens/channel_screen.dart';

class ThreadScreen extends ConsumerStatefulWidget {
  const ThreadScreen({required this.channelId, this.onClose, super.key});

  final String channelId;

  /// Set when this screen is a docked side pane rather than the pushed modal
  /// route: there is no navigator entry to pop, so the leading control closes
  /// the pane through this instead of the route's own back affordance.
  final VoidCallback? onClose;

  @override
  ConsumerState<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends ConsumerState<ThreadScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(_ensureThreadChannelRow());
  }

  @override
  void didUpdateWidget(ThreadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // This modal route reuses the State across a thread switch, so the new thread's channel row must be ensured again; initState ran only for the first.
    if (oldWidget.channelId != widget.channelId) {
      unawaited(_ensureThreadChannelRow());
    }
  }

  Future<void> _ensureThreadChannelRow() async {
    final channelId = widget.channelId;
    final api.ThreadParent parent;
    try {
      parent = await ref.read(threadParentProvider(channelId).future);
    } on api.ApiException {
      // Best effort: the title stays "Thread" and the read marker stays unfixed for this session, same as today.
      return;
    }
    if (!parent.isThread || !mounted) return;
    final store = await ref.read(storeProvider.future);
    await store.upsertChannels([
      api.Channel(
        id: channelId,
        name: threadChannelName,
        kind: 'text',
        createdAt: 0,
        parentMessageId: parent.parentMessageId,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final parent = ref
        .watch(threadParentProvider(widget.channelId))
        .valueOrNull;
    final parentName = parent?.parentChannelName;
    final title = parentName == null || parentName.isEmpty
        ? 'Thread'
        : 'Thread in #$parentName';
    // Docked beside the chat: its own raised surface, so the pane is not lost against the transcript it sits next to.
    final docked = widget.onClose != null;
    final surface = docked ? tokens.surfaceRaised : null;
    return Scaffold(
      backgroundColor: surface,
      appBar: AppBar(
        backgroundColor: surface,
        // Docked: a close, since the parent sits beside it, not behind. Routed: the automatic back button is a Material glyph; BackToButton's is the Lucide one every other screen uses.
        leading: widget.onClose != null
            ? IconButton(
                icon: const Icon(AppIcons.dismiss),
                tooltip: 'Close thread',
                onPressed: widget.onClose,
              )
            : const BackToButton(
                tooltip: 'Back to the conversation',
                fallback: Routes.channels,
              ),
        // container: true gives the title its own semantics node; see the doc comment above.
        title: Semantics(header: true, container: true, child: Text(title)),
        shape: Border(bottom: BorderSide(color: tokens.borderSubtle)),
        actions: [
          ChannelSearchAction(channelId: widget.channelId),
          const SizedBox(width: AppSpacing.s8),
        ],
      ),
      body: ChannelScreen(
        channelId: widget.channelId,
        isThread: true,
        autofocusComposer: docked,
      ),
    );
  }
}
