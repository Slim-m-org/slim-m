// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import '../providers/providers.dart';
import '../features/channels/providers/threads.dart';
import '../routing/breakpoints.dart';
import '../widgets/app_panel_reveal.dart';
import '../features/members/widgets/member_pane.dart';
import '../features/messages/screens/thread_screen.dart';

// The two docked third-pane slots (member roster, thread), split from home_shell.dart for the line budget; kept as private part-of classes so the shell's Row still names them.
/// Builds [build] with whether [channelId] is a DM, resolved from the local store.
Widget withChannelKind(
  WidgetRef ref,
  String channelId,
  Widget Function(bool isDm) build,
) => ref
    .watch(storeProvider)
    .maybeWhen(
      orElse: () => build(false),
      data: (store) => StreamBuilder<Channel?>(
        stream: store.watchChannelRow(channelId),
        builder: (context, snapshot) => build(snapshot.data?.kind == 'dm'),
      ),
    );

/// The wide-layout member pane's slot: width-animated, and withheld for a
/// DM regardless of [requested] (the header toggle's own answer, already
/// `memberPaneVisibleProvider`-gated) - that provider defaults open, so
/// hiding only the toggle would still leave the deployment roster showing
/// by default for a two-person conversation, the exact bug `ChannelHeader.isDm`
/// exists to name. [channelId] null (nothing selected) or a store not yet
/// resolved both read as "show": only a confirmed DM withholds it.
class MemberPaneSlot extends ConsumerWidget {
  const MemberPaneSlot({
    super.key,
    required this.channelId,
    required this.requested,
  });

  final String? channelId;
  final bool requested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!requested) return _animated(context, ref, false);
    final channelId = this.channelId;
    if (channelId == null) return _animated(context, ref, true);
    final storeAsync = ref.watch(storeProvider);
    return storeAsync.maybeWhen(
      orElse: () => _animated(context, ref, true),
      data: (store) => StreamBuilder<Channel?>(
        stream: store.watchChannelRow(channelId),
        builder: (context, snapshot) =>
            _animated(context, ref, snapshot.data?.kind != 'dm'),
      ),
    );
  }

  Widget _animated(BuildContext context, WidgetRef ref, bool show) => ClipRect(
    child: AnimatedContainer(
      duration: AppMotion.reduced(context, AppMotion.base),
      curve: AppMotion.entrance,
      width: show ? AppMemberPane.width : 0,
      child: show
          ? OverflowBox(
              minWidth: AppMemberPane.width,
              maxWidth: AppMemberPane.width,
              alignment: Alignment.centerLeft,
              child: AppPanelReveal(
                fromLeft: false,
                child: AppMemberPane(channelId: channelId),
              ),
            )
          : const SizedBox.shrink(),
    ),
  );
}

/// The docked thread, beside the transcript at expanded widths (UX1). Mirrors
/// [MemberPaneSlot]'s reveal exactly - an [AnimatedContainer] width that
/// unmounts its content when closed so a hidden pane stops fetching - but wraps
/// [ThreadScreen], whose close affordance clears [openThreadProvider] rather
/// than popping, since docked there is no route entry to pop.
class ThreadPaneSlot extends ConsumerWidget {
  const ThreadPaneSlot({
    super.key,
    required this.channelId,
    required this.requested,
  });

  final String? channelId;
  final bool requested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final id = channelId;
    final show = requested && id != null;
    return ClipRect(
      child: AnimatedContainer(
        duration: AppMotion.reduced(context, AppMotion.base),
        curve: AppMotion.entrance,
        width: show ? kThreadPaneWidth : 0,
        child: show
            ? OverflowBox(
                minWidth: kThreadPaneWidth,
                maxWidth: kThreadPaneWidth,
                alignment: Alignment.centerLeft,
                // Container, not DecoratedBox: only Container insets its child by the border, which an opaque Scaffold would otherwise paint over.
                child: Container(
                  decoration: BoxDecoration(
                    // Strong, not subtle: the pane's fill is only a step off the chat's, so the edge carries the division.
                    border: Border(
                      left: BorderSide(color: tokens.borderStrong),
                    ),
                  ),
                  child: AppPanelReveal(
                    fromLeft: false,
                    child: ThreadScreen(
                      channelId: id,
                      onClose: () =>
                          ref.read(openThreadProvider.notifier).state = null,
                    ),
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
