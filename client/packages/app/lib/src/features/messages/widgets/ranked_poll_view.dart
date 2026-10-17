// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The options and footer of a ranked poll, inside [PollView]'s card.
///
/// While ranking, a tap adds an option to the ballot (or takes it back off),
/// numbered in the order tapped, and nothing is sent until "Submit ranking":
/// a ranking is one decision, not a vote per tap. Once a ballot is in, the
/// bars show the last round of the instant runoff, with the winner marked
/// the way [PollView] marks a leading option, and the viewer's own ranks
/// stay numbered beside their choices.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../composer/widgets/poll_option_row.dart';
import '../../composer/widgets/poll_view.dart' show closesIn;

class RankedPollBody extends StatefulWidget {
  const RankedPollBody({
    super.key,
    required this.poll,
    required this.closed,
    required this.now,
    required this.onRank,
  });

  final api.Poll poll;
  final bool closed;
  final DateTime now;

  /// Submits a ranking, best first. Null makes the poll read-only.
  final ValueChanged<List<int>>? onRank;

  @override
  State<RankedPollBody> createState() => _RankedPollBodyState();
}

class _RankedPollBodyState extends State<RankedPollBody> {
  /// The ballot being built, or null when showing results.
  List<int>? _draft;

  bool get _canRank => !widget.closed && widget.onRank != null;

  bool get _ranking =>
      _canRank && (_draft != null || widget.poll.votedRanking == null);

  void _toggle(int position) {
    final draft = [...?_draft];
    if (!draft.remove(position)) draft.add(position);
    setState(() => _draft = draft);
  }

  void _submit(List<int> draft) {
    widget.onRank?.call(draft);
    setState(() => _draft = null);
  }

  @override
  Widget build(BuildContext context) {
    final poll = widget.poll;
    final ranking = _ranking;
    final draft = _draft ?? const <int>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ..._optionRows(ranking: ranking, draft: draft),
        _footer(context, ranking: ranking),
        if (ranking && (draft.isNotEmpty || poll.votedRanking != null)) ...[
          const SizedBox(height: AppSpacing.s8),
          _submitRow(draft),
        ],
      ],
    );
  }

  List<Widget> _optionRows({required bool ranking, required List<int> draft}) {
    final poll = widget.poll;
    final runoff = poll.runoff;
    final rounds = runoff?.rounds ?? const <Map<int, int>>[];
    final last = rounds.isEmpty ? const <int, int>{} : rounds.last;
    final total = last.values.fold<int>(0, (sum, v) => sum + v);
    final ranks = ranking ? draft : (poll.votedRanking ?? const <int>[]);
    return [
      for (final option in poll.options) ...[
        PollOptionRow(
          option: option,
          votes: last[option.position] ?? 0,
          totalVotes: total,
          selected: ranks.contains(option.position),
          rank: _rankOf(ranks, option.position),
          leading: total > 0 && runoff?.winner == option.position,
          note: _noteFor(rounds.length, last, option.position),
          onTap: ranking ? () => _toggle(option.position) : null,
        ),
        const SizedBox(height: AppSpacing.s4),
      ],
    ];
  }

  int? _rankOf(List<int> ranks, int position) {
    final index = ranks.indexOf(position);
    return index < 0 ? null : index + 1;
  }

  String? _noteFor(int roundCount, Map<int, int> last, int position) {
    if (roundCount > 1 && !last.containsKey(position)) return 'Out';
    return null;
  }

  Widget _footer(BuildContext context, {required bool ranking}) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      children: [
        Expanded(
          child: Text(
            rankedFooterText(
              widget.poll,
              ranking: ranking,
              closed: widget.closed,
              now: widget.now,
            ),
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
        if (!ranking && _canRank)
          AppButton(
            label: 'Change ranking',
            size: AppButtonSize.sm,
            variant: AppButtonVariant.ghost,
            onPressed: () => setState(() => _draft = const []),
          ),
      ],
    );
  }

  Widget _submitRow(List<int> draft) {
    final voted = widget.poll.votedRanking != null;
    return Row(
      children: [
        AppButton(
          label: 'Submit ranking',
          size: AppButtonSize.sm,
          variant: AppButtonVariant.primary,
          disabled: draft.isEmpty,
          onPressed: () => _submit(draft),
        ),
        const SizedBox(width: AppSpacing.s8),
        AppButton(
          label: voted ? 'Cancel' : 'Clear',
          size: AppButtonSize.sm,
          variant: AppButtonVariant.ghost,
          onPressed: () => setState(() => _draft = voted ? null : const []),
        ),
      ],
    );
  }
}

/// What the line under a ranked poll's options says.
String rankedFooterText(
  api.Poll poll, {
  required bool ranking,
  required bool closed,
  required DateTime now,
}) {
  final closeAt = poll.closeAt;
  final closes = closed || closeAt == null ? '' : closesIn(closeAt, now);
  if (ranking) return 'Tap options in order of preference. $closes'.trim();
  final count = poll.totalVotes;
  if (count == 0) {
    return closed ? 'No one voted.' : 'No votes yet. $closes'.trim();
  }
  final rounds = poll.runoff?.rounds.length ?? 0;
  final parts = [
    '$count vote${count == 1 ? '' : 's'}',
    if (poll.runoff?.winner == null)
      'tied'
    else if (rounds > 1)
      'decided in round $rounds',
  ];
  return [...parts, if (closes.isNotEmpty) closes].join(' - ');
}
