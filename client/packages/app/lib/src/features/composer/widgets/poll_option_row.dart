// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One poll option as a bar: shared by [PollView] and [RankedPollView], so a
/// ranked poll reads exactly like an ordinary one apart from its rank marks.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'poll_text.dart';

/// Wide enough for a leading option's icon plus "100%" at [AppText.caption],
/// so every option's trailing column lines up regardless of digit count or
/// whether that particular row carries the leading glyph.
const double _percentColumnWidth = 72;

/// The fill under an option's own label: one colour for every option,
/// because the bar's job is the share and the share is already the width.
///
/// It used to vary - `accentSoft` for your own vote, `textSecondary` for the
/// leading one - and both readings were wrong against the track they sit on.
/// The track is [AppTokens.borderSubtle], and `accentSoft` is *darker* than
/// it in both themes (dark #1D2B33 on #2E333A, light #DAE9F2 on #DCE0E5), so
/// the option you voted for rendered as a recess while the one you did not
/// rendered as a bar. The owner reported exactly that, on a 50/50 poll where
/// two identical shares drew two different colours.
///
/// `textSecondary` had its own problem: at dark #A7AEB6 under
/// [AppTokens.textPrimary] the label on top of a leading bar fell to roughly
/// 1.8:1.
///
/// Neither state loses anything by this. "Yours" is the checkmark beside the
/// label, "leading" is its own glyph beside the percentage, and both already
/// carry a semibold label - none of it was ever colour alone.
Color _fillColor(AppTokens tokens) => tokens.borderStrong;

/// One option: a full-height track, the fill bar over it, and the label and
/// percentage on top.
///
/// Those three are stacked, and a `Stack` puts a child that is not explicitly
/// positioned at its own top-start corner - so the label hugged the top edge
/// of what is a full touch-height row, leaving the rest of it empty
/// (reported 2026-08-13, "the poll items text is not centered"). The stack's
/// own alignment is what fixes it. Wrapping the label row in a
/// `Positioned.fill` instead looks more explicit and is wrong: it takes that
/// child out of what the stack measures itself against, and the percentage
/// column then overflows.
class PollOptionRow extends StatefulWidget {
  const PollOptionRow({
    super.key,
    required this.option,
    required this.votes,
    required this.totalVotes,
    required this.selected,
    required this.leading,
    required this.onTap,
    this.rank,
    this.note,
  });

  final api.PollOption option;

  /// The count the bar shows, out of [totalVotes]: the option's own votes,
  /// or its last runoff round on a ranked poll.
  final int votes;
  final int totalVotes;
  final bool selected;

  /// Where the viewer ranked this option, 1-based, on a ranked poll. Shown
  /// as a number in place of the vote check.
  final int? rank;

  /// Said in place of the percentage, for an option the runoff dropped.
  final String? note;

  /// Whether this option is ahead of (or has won against) every other.
  /// Never true for more than one option in the same poll.
  final bool leading;
  final VoidCallback? onTap;

  @override
  State<PollOptionRow> createState() => _PollOptionRowState();
}

class _PollOptionRowState extends State<PollOptionRow> {
  bool _focused = false;

  void _activate() {
    if (widget.onTap != null) widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final totalVotes = widget.totalVotes;
    final selected = widget.selected;
    final leading = widget.leading;
    final rank = widget.rank;
    final fraction = totalVotes > 0 ? widget.votes / totalVotes : 0.0;
    final percent = (fraction * 100).round();
    // controlMd (34px) clears the pointer floor, not the touch one.
    final touch = AppTouchTargets.of(context);

    return Semantics(
      button: widget.onTap != null,
      selected: selected,
      label:
          '${widget.option.label}, ${_tally(percent)}'
          '${rank != null ? ', your choice $rank' : ''}'
          '${selected && rank == null ? ', your vote' : ''}'
          '${leading ? ', leading' : ''}',
      child: FocusableActionDetector(
        enabled: widget.onTap != null,
        mouseCursor: widget.onTap != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => _activate(),
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          // Without this the label Text's own auto-generated semantics merges with the explicit label above into a doubled announcement.
          child: ExcludeSemantics(
            child: Container(
              height: touch ? AppSizes.rowTouch : AppSizes.controlMd,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                // Plain separator normally; focusRing on keyboard focus only, never for selection.
                border: Border.all(
                  color: _focused ? tokens.focusRing : tokens.borderSubtle,
                  width: _focused ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              // Centred rather than a Stack's top-start default; see PollOptionRow's own doc comment.
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // The track, always visible, so a zero-vote option still reads as a bar.
                  Positioned.fill(child: Container(color: tokens.borderSubtle)),
                  // Start-aligned: the stack's centre alignment would float a partial bar mid-track.
                  Positioned.fill(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: FractionallySizedBox(
                        widthFactor: fraction.clamp(0, 1),
                        heightFactor: 1,
                        child: Container(color: _fillColor(tokens)),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s8,
                    ),
                    child: _content(tokens, percent),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _tally(int percent) {
    final note = widget.note;
    if (note != null) return note.toLowerCase();
    if (widget.totalVotes <= 0) return 'no votes yet';
    final votes = widget.votes;
    return '$percent percent, $votes vote${votes == 1 ? '' : 's'}';
  }

  Widget _content(AppTokens tokens, int percent) {
    final rank = widget.rank;
    final emphasised = widget.selected || widget.leading;
    return Row(
      children: [
        // The vote is never colour alone: a check beside the label carries it too, like presence elsewhere.
        if (rank != null) ...[
          _RankMark(rank: rank, tokens: tokens),
          const SizedBox(width: AppSpacing.s4),
        ] else if (widget.selected) ...[
          Icon(AppIcons.check, size: AppSizes.icon16, color: tokens.accentFill),
          const SizedBox(width: AppSpacing.s4),
        ],
        Expanded(
          child: PollText(
            widget.option.label,
            maxLines: 1,
            style: AppText.ui.copyWith(
              fontWeight: emphasised ? AppWeights.semi : AppWeights.regular,
            ),
          ),
        ),
        // Hidden entirely rather than a silent "0%": every row shares one poll-level totalVotes, so this is all-or-nothing across the whole card.
        if (widget.totalVotes > 0 || widget.note != null)
          _percentColumn(tokens, percent),
      ],
    );
  }

  Widget _percentColumn(AppTokens tokens, int percent) {
    return SizedBox(
      width: _percentColumnWidth,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Never colour alone: the icon and the label's own semibold weight both carry "leading", not just this row reading lighter than its neighbour.
          if (widget.leading) ...[
            Icon(
              AppIcons.pollLeading,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
            const SizedBox(width: AppSpacing.s4),
          ],
          Text(
            widget.note ?? '$percent%',
            style: AppText.caption.copyWith(
              color: tokens.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// The viewer's rank for an option: a number in a small tinted square, in
/// the accent because it marks the viewer's own choice, like the vote check.
class _RankMark extends StatelessWidget {
  const _RankMark({required this.rank, required this.tokens});

  final int rank;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => Container(
    width: AppSizes.icon16,
    height: AppSizes.icon16,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: tokens.accentFill,
      borderRadius: BorderRadius.circular(AppRadii.control / 2),
    ),
    child: Text(
      '$rank',
      style: AppText.caption.copyWith(
        color: tokens.accentOn,
        fontWeight: AppWeights.semi,
        height: 1,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}
