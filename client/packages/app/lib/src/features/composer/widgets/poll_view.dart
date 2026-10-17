// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renders a poll message: the question, each option with its live tally,
/// and a tap to vote. An ordinary poll takes exactly one vote per user (a
/// second vote replaces the first, it never adds to it: see
/// `store::polls::vote_poll`); a ranked poll hands its options to
/// [RankedPollBody] instead. Voting is refused server-side once the poll
/// is closed regardless of what this renders. The client's clock only ever
/// closes a poll early in the view, at its `close_at`, never reopens one the
/// server called closed, so a skewed clock can hide a few seconds of voting
/// at worst.
///
/// Each option bar is a track (`borderSubtle`, always visible) with a
/// proportional fill on top: `borderStrong` for an ordinary option, so the
/// share reads by contrast alone, and `accentSoft` for the one you voted
/// for - one of the seven closed accent roles in
/// `docs/decisions/0004-visual-identity-review.md`. The option's own border
/// is `borderSubtle` for selection, never accent-coloured: selection is a
/// fill plus a marker (the checkmark), while an accent outline means
/// keyboard focus (`AppTokens.focusRing`'s own house rule), and it turns
/// `focusRing` on real keyboard focus - the one case that rule reserves it
/// for.
///
/// Two more cues, neither of them colour alone. The option strictly ahead
/// of every other - a unique highest vote count, never a tie - carries
/// [AppIcons.pollLeading] beside its own percentage plus a semibold label,
/// in `textSecondary` rather than the accent: the accent's seven roles all
/// mean "this concerns you", and "this is winning" is not one of them. A
/// tie at the top marks nobody, since "leading" means ahead of everybody
/// else. And a poll nobody has voted in yet says so in words (see
/// [_footerText]) instead of drawing three identical, silent "0%" bars -
/// that repetition, not the zero itself, is what read as broken.
///
/// A per-option vote count was considered and dropped: the bar's own width
/// already carries the share, the percentage names it precisely, and the
/// running total belongs once, in the footer - repeating it on every row
/// would widen every option for a number the footer already states.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'poll_option_row.dart';
import 'poll_text.dart';
import '../../messages/widgets/ranked_poll_view.dart';

class PollView extends StatefulWidget {
  const PollView({
    super.key,
    required this.poll,
    required this.onVote,
    this.onRank,
  });

  final api.Poll poll;
  final ValueChanged<int> onVote;

  /// Submits a ranking on a ranked poll. Null leaves a ranked poll read-only.
  final ValueChanged<List<int>>? onRank;

  @override
  State<PollView> createState() => _PollViewState();
}

class _PollViewState extends State<PollView> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(PollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.poll.closeAt != widget.poll.closeAt ||
        oldWidget.poll.closed != widget.poll.closed) {
      _schedule();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Wakes at the next minute or at the close, whichever is sooner, so the
  /// countdown stays current and the poll closes on time without a refetch.
  void _schedule() {
    _tick?.cancel();
    final closeAt = widget.poll.closeAt;
    if (closeAt == null || pollClosed(widget.poll, clock.now())) return;
    final left = closeAt - clock.now().millisecondsSinceEpoch;
    final wait = left < 60000 ? left : 60000 - (left % 60000);
    _tick = Timer(Duration(milliseconds: wait.clamp(1, 60000)), () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  Widget build(BuildContext context) {
    final poll = widget.poll;
    final onVote = widget.onVote;
    final now = clock.now();
    final closed = pollClosed(poll, now);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final canVote = !closed;
    final leadingPosition = _leadingPosition(poll);

    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.all(AppSpacing.s12),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      // min: a poll card must hug its own content, not fill a bounded parent.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: PollText(
                  poll.question,
                  style: AppText.body.copyWith(fontWeight: AppWeights.semi),
                ),
              ),
              // A closed poll used to say so only in the fine print below the options; this is the glance-able version.
              if (closed) ...[
                const SizedBox(width: AppSpacing.s8),
                const AppBadge(variant: AppBadgeVariant.tag, label: 'Closed'),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.s8),
          if (poll.ranked)
            RankedPollBody(
              poll: poll,
              closed: closed,
              now: now,
              onRank: widget.onRank,
            )
          else ...[
            for (final option in poll.options) ...[
              PollOptionRow(
                option: option,
                votes: option.votes,
                totalVotes: poll.totalVotes,
                selected: poll.votedOption == option.position,
                leading: leadingPosition == option.position,
                onTap: canVote ? () => onVote(option.position) : null,
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
            Text(
              _footerText(poll, closed: closed, now: now),
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// The option strictly ahead of every other, or null when nobody has voted
/// yet or the top spot is tied. See the library doc above for why a tie
/// marks nobody.
int? _leadingPosition(api.Poll poll) {
  if (poll.totalVotes == 0) return null;
  var topVotes = -1;
  var topPosition = -1;
  var tied = false;
  for (final option in poll.options) {
    if (option.votes > topVotes) {
      topVotes = option.votes;
      topPosition = option.position;
      tied = false;
    } else if (option.votes == topVotes) {
      tied = true;
    }
  }
  if (topVotes <= 0 || tied) return null;
  return topPosition;
}

/// What the line under the options says. A poll with no votes yet says so
/// in words rather than every option drawing an identical, silent "0%" -
/// see the library doc above for why that read as broken.
String _footerText(
  api.Poll poll, {
  required bool closed,
  required DateTime now,
}) {
  final count = poll.totalVotes;
  final votes = count == 0
      ? (closed ? 'No one voted.' : 'No votes yet. Tap an option to vote.')
      : '$count vote${count == 1 ? '' : 's'}';
  final closeAt = poll.closeAt;
  if (closed || closeAt == null) return votes;
  return '$votes ${count == 0 ? '' : '- '}${closesIn(closeAt, now)}'.trim();
}

/// Closed by the server, or past its `close_at` by this device's clock.
bool pollClosed(api.Poll poll, DateTime now) {
  final closeAt = poll.closeAt;
  return poll.closed ||
      (closeAt != null && now.millisecondsSinceEpoch >= closeAt);
}

/// "Closes in 5 min.", "Closes in 3 h.", "Closes in 1 day.".
String closesIn(int closeAt, DateTime now) {
  final left = Duration(milliseconds: closeAt - now.millisecondsSinceEpoch);
  if (left.inMinutes < 1) return 'Closes in under a minute.';
  if (left.inHours < 1) return 'Closes in ${left.inMinutes} min.';
  if (left.inHours < 24) return 'Closes in ${left.inHours} h.';
  final days = left.inDays;
  return 'Closes in $days day${days == 1 ? '' : 's'}.';
}
