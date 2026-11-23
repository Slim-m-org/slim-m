// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the shell resolves once per build: which panes dock, and the rail width.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../features/canvas/providers/canvas_open.dart';
import '../features/canvas/screens/canvas_fullscreen.dart';
import '../features/channels/providers/channel_by_id_provider.dart';
import '../features/channels/providers/rail_width_preference.dart';
import '../features/channels/providers/threads.dart';
import '../features/channels/widgets/channel_rail.dart';
import '../features/members/widgets/member_pane.dart';
import '../features/modules/widgets/module_panel_slot.dart';
import '../features/video/providers/desktop_video.dart';
import '../features/voice/providers/dm_call.dart';
import '../providers/sync_controller.dart' show initialSyncCompleteProvider;
import '../routing/breakpoints.dart';

ShellFacts resolveShellFacts(
  WidgetRef ref,
  LayoutClass layout,
  Size size,
  String? selected,
) {
  final width = size.width;
  // CanvasBar is the only header while open (ConversationPane's doc); the compact app bar below would otherwise stack a second one above it.
  final canvasOpen =
      selected != null && ref.watch(canvasOpenProvider) == selected;
  // DmCallBar is the same: a DM's call pane replaces the header too.
  final dmCallOpen =
      selected != null && ref.watch(dmCallOpenProvider) == selected;
  // The canvas asked for the whole pane; the rail and the roster are exactly the chrome it asked to be rid of, and both unmount rather than sitting at zero width, so neither keeps polling behind it.
  final fullscreenChannel = ref.watch(canvasFullscreenProvider);
  final canvasFullscreen = canvasOpen && fullscreenChannel == selected;
  // The header toggle can only hide the pane, not summon room that is not there (see LayoutClass.fitsMemberPane).
  final membersFit = layout.fitsMemberPane(width);
  // A docked thread and the roster share the third-pane slot, so the roster yields (see fitsThreadPane); narrower, the thread stays a modal route.
  final openThread = dockedThreadBeside(
    ref.watch(dockedThreadsProvider),
    selected,
  );
  final threadFits = layout.fitsThreadPane(width);
  final showThread = openThread != null && threadFits && !canvasFullscreen;
  // Once synced, a channel the store lacks is one the viewer cannot see: ChannelNotFound owns the pane, with no roster or members control.
  final channelRow = selected == null
      ? null
      : ref.watch(
          channelByIdProvider(selected).select(
            // Only whether the row is there: the row itself changes with every message and read marker.
            (row) => (
              loaded: row.hasValue,
              missing: row is AsyncData<Channel?> && row.value == null,
            ),
          ),
        );
  final synced = ref.watch(initialSyncCompleteProvider);
  final notFound = (channelRow?.missing ?? false) && synced;
  final membersWanted =
      membersFit &&
      !notFound &&
      !canvasFullscreen &&
      !showThread &&
      memberPaneWanted(ref, size);
  // A docked video takes the third pane, with the roster under it; a docked thread there sends it to the strip above the chat.
  final videoDocked = ref.watch(
    desktopVideoProvider.select((v) => v?.docked ?? false),
  );
  final sideFree = threadFits && !showThread && !canvasFullscreen;
  final panelSide = modulePanelDocked(ref, fits: sideFree);
  final videoSide = videoDocked && sideFree && !panelSide;
  final showMembers = membersWanted && !videoSide && !panelSide;
  final dockedPane = switch ((
    showThread || videoSide || panelSide,
    showMembers,
  )) {
    (true, _) => kThreadPaneWidth,
    (_, true) => AppMemberPane.width,
    _ => 0.0,
  };
  return ShellFacts(
    selected: selected,
    canvasOpen: canvasOpen,
    dmCallOpen: dmCallOpen,
    canvasFullscreen: canvasFullscreen,
    membersFit: membersFit,
    openThread: openThread,
    threadFits: threadFits,
    showThread: showThread,
    showMembers: showMembers,
    videoSide: videoSide,
    panelSide: panelSide,
    videoStrip: videoDocked && !videoSide && !canvasFullscreen,
    membersUnderVideo: videoSide && membersWanted,
    notFound: notFound,
    rosterPending: channelRow != null && !channelRow.loaded && synced,
    railWidth: _railWidth(ref, layout, width, dockedPane),
  );
}

double _railWidth(
  WidgetRef ref,
  LayoutClass layout,
  double width,
  double dockedPane,
) {
  final defaultRailWidth = layout == LayoutClass.expanded
      ? ChannelRail.expandedWidth
      : ChannelRail.mediumWidth;
  // A dragged width wins, but never squeezes the conversation below its floor beside a docked pane.
  final railRoom =
      width - AppSizes.rowPointer - dockedPane - kMinTranscriptWidth;
  return math.min(
    ref.watch(railWidthControllerProvider) ?? defaultRailWidth,
    math.max(defaultRailWidth, railRoom),
  );
}

/// What one build of the shell resolved once, shared by its scaffolds.
class ShellFacts {
  const ShellFacts({
    required this.selected,
    required this.canvasOpen,
    required this.dmCallOpen,
    required this.canvasFullscreen,
    required this.membersFit,
    required this.openThread,
    required this.threadFits,
    required this.showThread,
    required this.showMembers,
    required this.videoSide,
    required this.panelSide,
    required this.videoStrip,
    required this.membersUnderVideo,
    required this.notFound,
    required this.rosterPending,
    required this.railWidth,
  });

  final String? selected;
  final bool canvasOpen;
  final bool dmCallOpen;
  final bool canvasFullscreen;
  final bool membersFit;
  final String? openThread;
  final bool threadFits;
  final bool showThread;
  final bool showMembers;
  final bool videoSide;
  final bool panelSide;
  final bool videoStrip;
  final bool membersUnderVideo;
  final bool notFound;
  final bool rosterPending;
  final double railWidth;
}
