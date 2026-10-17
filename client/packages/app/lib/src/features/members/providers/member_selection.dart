// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picking several members out of the member pane in order to moderate them
/// all at once.
///
/// The counterpart to [MessageSelection], and the answer to the same gap on
/// the other half of MOD13: member search could already *find* a wave of
/// throwaway accounts registered through one invite, and the only way to act
/// on what it found was one confirmation dialog per account.
///
/// Deployment-wide rather than per channel, unlike the message selection this
/// mirrors, because both verbs behind it are: a removal and a timeout apply to
/// the whole Space, so a selection scoped to wherever the pane happened to be
/// open would suggest a narrowing that does not exist.
///
/// Selection holds ids rather than members, for [MessageSelection]'s reason: a
/// selected member can be removed by somebody else, or fall out of a filtered
/// list, while the bar is still open. A stale id costs nothing - the server
/// treats removing an already-removed member as a replace rather than an
/// error - and pruning the set on every rebuild would make the selection
/// flicker as presence changes.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The most members one bulk moderation request may name.
///
/// Mirrors `MAX_BULK_MEMBER_IDS` in `http/members_bulk.rs`, which rejects a
/// longer list with 400. Enforced here too so the cap is reached as a control
/// that stops responding rather than as a request that fails.
const int maxBulkMemberIds = 64;

/// What is selected in the member pane, and whether selection is on at all.
///
/// [active] is separate from `ids.isEmpty` for [MessageSelection]'s reason:
/// deselecting the last member leaves the mode running rather than closing the
/// bar out from under somebody still choosing.
@immutable
class MemberSelection {
  const MemberSelection({this.ids = const {}, this.active = false});

  final Set<String> ids;
  final bool active;

  int get count => ids.length;
  bool contains(String id) => ids.contains(id);

  /// True once no further member may be added. Deselecting still works.
  bool get atCap => ids.length >= maxBulkMemberIds;
}

class MemberSelectionController extends StateNotifier<MemberSelection> {
  MemberSelectionController() : super(const MemberSelection());

  /// Turns selection on with nothing picked, which is how the pane's header
  /// enters the mode: the affordance is about the list, not about one member,
  /// so there is nobody to have selected yet.
  void enter() => state = const MemberSelection(active: true);

  /// Turns selection on with [id] already picked, for an entry point that
  /// starts from one member.
  void start(String id) => state = MemberSelection(ids: {id}, active: true);

  /// Adds [id], or removes it if already selected.
  ///
  /// At the cap this adds nothing but still removes, so somebody who picked
  /// one member too many has a way back that is not cancelling everything.
  void toggle(String id) {
    if (!state.active) return;
    final next = {...state.ids};
    if (!next.remove(id)) {
      if (state.atCap) return;
      next.add(id);
    }
    state = MemberSelection(ids: next, active: true);
  }

  /// Ends selection mode and forgets everything picked.
  ///
  /// Called on the compact layout when the member drawer closes
  /// (`home_shell.dart`'s `onEndDrawerChanged`), which the wide layout gets
  /// for free. A `Scaffold` builds its `endDrawer` child whether or not the
  /// drawer is open, so the pane stays mounted there and these autoDispose
  /// providers never reset; without that call a forgotten selection would
  /// resurface the next time the roster slid in.
  void clear() => state = const MemberSelection();
}

/// The member pane's selection. Deployment-wide, so not a family.
final memberSelectionProvider =
    StateNotifierProvider.autoDispose<
      MemberSelectionController,
      MemberSelection
    >((ref) => MemberSelectionController());

/// Ends member selection when the compact layout's member drawer closes.
///
/// Lives here rather than inline in `home_shell.dart` because that file sits
/// at the file-budget ceiling, and because the reason belongs beside the
/// state it clears: see [MemberSelectionController.clear].
void endSelectionOnDrawerClose(WidgetRef ref, bool opened) {
  if (!opened) ref.read(memberSelectionProvider.notifier).clear();
}
