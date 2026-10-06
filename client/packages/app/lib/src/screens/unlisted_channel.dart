// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the conversation pane shows for an id that is not in the channel list
/// once the first sync has finished.
///
/// A thread is left out of that list on purpose, so a push for a thread reply
/// (or a message link into one) arrives here too. The server says which it is:
/// a thread opens beside its parent channel, anything else is not found.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/threads.dart';
import '../routing/routes.dart';
import 'channel_not_found.dart';

class UnlistedChannel extends ConsumerWidget {
  const UnlistedChannel({required this.channelId, super.key});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parent = ref.watch(threadParentProvider(channelId));
    return parent.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: AppErrorState(
            message: 'Could not open this channel.',
            onRetry: () => ref.invalidate(threadParentProvider(channelId)),
          ),
        ),
      ),
      data: (found) {
        final parentChannelId = found.parentChannelId;
        if (parentChannelId == null) return const ChannelNotFound();
        return _OpenThread(
          parentChannelId: parentChannelId,
          threadId: channelId,
        );
      },
    );
  }
}

/// Goes to the parent channel and pushes the thread over it, so back from the
/// thread lands in the channel it hangs off.
class _OpenThread extends StatefulWidget {
  const _OpenThread({required this.parentChannelId, required this.threadId});

  final String parentChannelId;
  final String threadId;

  @override
  State<_OpenThread> createState() => _OpenThreadState();
}

class _OpenThreadState extends State<_OpenThread> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final router = GoRouter.of(context);
      router.go(Routes.channel(widget.parentChannelId));
      router.push(Routes.thread(widget.threadId));
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}
