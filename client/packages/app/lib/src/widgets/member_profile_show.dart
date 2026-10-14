// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens the member card: an anchored popover on a pointer layout, a bottom
/// sheet on a compact one. The card itself is `member_profile.dart`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'member_profile.dart';
import 'member_profile_popover.dart';

/// The popover's width on a pointer layout, from the design.
const double memberPopoverWidth = 300;

/// Opens the profile surface for [profile], anchored to [anchor] where there
/// is a pointer and presented as a sheet where there is not.
///
/// [anchor] is the widget the popover hangs off; the caller passes its own
/// context so the popover lands beside the row that was clicked rather than
/// in the middle of the window.
///
/// On compact width the roster this popover can open from lives in a
/// `Scaffold.endDrawer`, whose open state lives on the `ScaffoldState` and
/// outlives a `go_router` navigation - the shell's `Scaffold` is reused
/// rather than rebuilt. [Scaffold.maybeOf] is read from [anchor] here, before
/// anything else runs, so a navigating action can close it as part of
/// itself; see [MemberProfileBody.memberPaneScaffold].
Future<void> showMemberProfile(
  BuildContext anchor, {
  required api.UserProfile profile,
  String? callChannelName,
  bool initiallyModerating = false,
  String? channelId,
}) {
  // Read before anything pops: a popped context has no navigator above it.
  final host = Navigator.of(anchor, rootNavigator: true).context;
  final compact = MediaQuery.sizeOf(anchor).width < kCompactWidth;
  final memberPaneScaffold = Scaffold.maybeOf(anchor);

  if (compact) {
    // Its own controller reads the platform's own reduce-motion feature, never this app's MotionOverride; see sheet.dart's library doc.
    final noAnimation = AppMotion.isReduced(anchor)
        ? AnimationStyle.noAnimation
        : null;
    return showModalBottomSheet<void>(
      context: anchor,
      isScrollControlled: true,
      showDragHandle: true,
      sheetAnimationStyle: noAnimation,
      builder: (context) => SafeArea(
        top: false,
        child: MemberProfileBody(
          profile: profile,
          callChannelName: callChannelName,
          compact: true,
          host: host,
          memberPaneScaffold: memberPaneScaffold,
          initiallyModerating: initiallyModerating,
          channelId: channelId,
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  final box = anchor.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
  final origin = box == null || overlay == null
      ? Offset.zero
      : box.localToGlobal(Offset.zero, ancestor: overlay);
  final anchorSize = box?.size ?? Size.zero;

  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: AppMotion.reduced(anchor, AppMotion.base),
    pageBuilder: (context, _, __) => AnchoredMemberPopover(
      origin: origin,
      anchorSize: anchorSize,
      child: MemberProfileBody(
        profile: profile,
        callChannelName: callChannelName,
        compact: false,
        host: host,
        memberPaneScaffold: memberPaneScaffold,
        initiallyModerating: initiallyModerating,
        channelId: channelId,
        onDone: () => Navigator.of(context).pop(),
      ),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.entrance,
        reverseCurve: AppMotion.exit,
      );
      return FadeTransition(
        opacity: curved,
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, (1 - curved.value) * 8),
            child: child,
          ),
          child: child,
        ),
      );
    },
  );
}
