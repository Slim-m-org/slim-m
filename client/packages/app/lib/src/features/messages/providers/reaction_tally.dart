// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message's reaction chips after a live frame or the viewer's own tap.
library;

import 'package:slimm_api/api.dart' as api;

/// The chips a `reactions.changed` frame describes, with the viewer's own flag
/// from the frame, or from [known] when the server is older than the flag.
///
/// An emoji in [pending] has a toggle of the viewer's still on its way, so the
/// frame may predate it: the chip keeps the flag the viewer last chose, and the
/// count moves by one to match.
List<api.ReactionSummary> reactionsFromFrame(
  List<api.ReactionTally> tallies,
  List<api.ReactionSummary> known, {
  Set<String> pending = const {},
}) {
  // any() rather than firstWhere(orElse:): a covariant List<Never> here threw on the orElse closure (iOS log, 2026-10-22).
  bool knownReacted(String emoji) =>
      known.any((r) => r.emoji == emoji && r.reacted);
  final next = <api.ReactionSummary>[];
  for (final tally in tallies) {
    final framed = tally.reacted;
    final held = pending.contains(tally.emoji) || framed == null;
    final reacted = held ? knownReacted(tally.emoji) : framed;
    final count = tally.count + _ownShift(framed, reacted);
    if (count <= 0) continue;
    next.add(
      api.ReactionSummary(emoji: tally.emoji, count: count, reacted: reacted),
    );
  }
  for (final emoji in pending) {
    if (tallies.any((t) => t.emoji == emoji) || !knownReacted(emoji)) continue;
    next.add(api.ReactionSummary(emoji: emoji, count: 1, reacted: true));
  }
  return next;
}

/// How far the viewer's own [reacted] moves a count the frame computed with [framed].
int _ownShift(bool? framed, bool reacted) {
  if (framed == null || framed == reacted) return 0;
  return reacted ? 1 : -1;
}

/// [existing] with the viewer's own [emoji] turned on or off ([active]).
List<api.ReactionSummary> reactionsAfterToggle(
  List<api.ReactionSummary> existing,
  String emoji, {
  required bool active,
}) {
  final index = existing.indexWhere((r) => r.emoji == emoji);
  final next = [...existing];
  if (index < 0) {
    if (active) {
      next.add(api.ReactionSummary(emoji: emoji, count: 1, reacted: true));
    }
    return next;
  }
  final current = next[index];
  if (current.reacted == active) return next;
  final count = current.count + (active ? 1 : -1);
  if (count <= 0) {
    next.removeAt(index);
  } else {
    next[index] = api.ReactionSummary(
      emoji: emoji,
      count: count,
      reacted: active,
    );
  }
  return next;
}
