// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone shell's scaffold: the channel rail as a start drawer, the roster
/// as an end drawer, both dragged by finger from their own edge.
library;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart' show AppHaptics;

import '../providers/channel_by_id_provider.dart';
import '../providers/member_selection.dart';
import '../routing/routes.dart';
import '../screens/voice_text_pane.dart' show voiceChatPaneVisibleProvider;
import 'channel_rail_drawer.dart';
import 'compact_channel_app_bar.dart';
import 'drawer_edge_drag.dart';
import 'member_pane.dart';

class CompactDrawerScaffold extends ConsumerStatefulWidget {
  const CompactDrawerScaffold({
    required this.channelId,
    required this.body,
    required this.showAppBar,
    required this.showRail,
    required this.showMembers,
    super.key,
  });

  final String channelId;
  final Widget body;
  final bool showAppBar;

  /// False where the pane above also claims the left edge itself (the canvas).
  final bool showRail;

  final bool showMembers;

  @override
  ConsumerState<CompactDrawerScaffold> createState() =>
      _CompactDrawerScaffoldState();
}

class _CompactDrawerScaffoldState extends ConsumerState<CompactDrawerScaffold> {
  bool _railOpen = false;

  /// Flutter reports the 50% crossing mid-drag and then the settle again; only a change of answer is a decision.
  void _onRailChanged(bool open) {
    if (open == _railOpen) return;
    _railOpen = open;
    AppHaptics.selection();
  }

  @override
  Widget build(BuildContext context) {
    final channelId = widget.channelId;
    final body = widget.body;
    final showAppBar = widget.showAppBar;
    final showRail = widget.showRail;
    final showMembers = widget.showMembers;
    final edgeWidth = drawerEdgeDragWidth(context);
    final chatOverCall = voiceChatOverCall(ref, channelId);
    void back() {
      if (chatOverCall) {
        ref.read(voiceChatPaneVisibleProvider.notifier).state = false;
      } else {
        context.go(Routes.channels);
      }
    }

    return PopScope(
      canPop: !chatOverCall,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: DrawerEdgeDrag(
        builder: (context, restore) => Scaffold(
          appBar: showAppBar
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(
                    CompactChannelAppBar.height,
                  ),
                  child: restore(
                    CompactChannelAppBar(channelId: channelId, onBack: back),
                  ),
                )
              : null,
          drawer: showRail
              ? restore(CompactChannelRailDrawer(selectedChannelId: channelId))
              : null,
          drawerEdgeDragWidth: edgeWidth,
          // Down, not start (both drawers): the drawer then follows from the first pixel instead of from where the touch slop was crossed.
          drawerDragStartBehavior: DragStartBehavior.down,
          onDrawerChanged: _onRailChanged,
          onEndDrawerChanged: (open) => endSelectionOnDrawerClose(ref, open),
          // The roster slides in from the right: the conversation is the only pane at this width.
          endDrawer: showMembers
              ? restore(
                  Drawer(
                    width: AppMemberPane.width,
                    child: SafeArea(child: AppMemberPane(channelId: channelId)),
                  ),
                )
              : null,
          // No rail here, so the connection bar mounts under the app bar; one SafeArea wraps the whole column, so no child insets itself and opens a gap or a dead band.
          body: restore(SafeArea(child: body)),
        ),
      ),
    );
  }
}

/// Whether a voice channel's chat is showing over its call, so back should close the chat first.
bool voiceChatOverCall(WidgetRef ref, String channelId) {
  final kind = ref.watch(channelByIdProvider(channelId)).valueOrNull?.kind;
  return kind == 'voice' && ref.watch(voiceChatPaneVisibleProvider);
}
