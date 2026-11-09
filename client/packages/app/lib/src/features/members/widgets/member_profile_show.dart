// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens the member card: an anchored popover on a pointer layout, a bottom
/// sheet on a compact one. The card itself is `member_profile.dart`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;

import 'member_profile.dart';
import '../../../widgets/anchored_popover_or_sheet.dart';

/// The popover's width on a pointer layout, from the design.
const double memberPopoverWidth = 300;

/// Opens the profile surface for [profile], anchored to [anchor] where there
/// is a pointer and presented as a sheet where there is not.
///
/// [anchor] is the widget the popover hangs off; the caller passes its own
/// context so the popover lands beside the row that was clicked rather than
/// in the middle of the window.
///
/// [profileOnly] drops the action rows on a pointer layout, where right click
/// reaches them; a compact sheet keeps them, as long press is its only other way.
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
  bool profileOnly = false,
}) {
  // Read before anything pops: a popped context has no navigator above it.
  final host = Navigator.of(anchor, rootNavigator: true).context;
  final memberPaneScaffold = Scaffold.maybeOf(anchor);

  Widget body(BuildContext context, {required bool compact}) =>
      MemberProfileBody(
        profile: profile,
        callChannelName: callChannelName,
        compact: compact,
        host: host,
        memberPaneScaffold: memberPaneScaffold,
        initiallyModerating: initiallyModerating,
        channelId: channelId,
        profileOnly: compact ? false : profileOnly,
        onDone: () => Navigator.of(context).pop(),
      );

  return showAnchoredPopoverOrSheet<void>(
    anchor,
    sheetScrolls: true,
    // The banner runs to the sheet's rounded top edge, as it does to the popover's.
    sheetHandleOverContent: true,
    popoverBuilder: (context) => body(context, compact: false),
    sheetBuilder: (context) => body(context, compact: true),
  );
}
