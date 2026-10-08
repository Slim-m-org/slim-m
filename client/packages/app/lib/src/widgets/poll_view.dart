// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renders a poll message: the question, each option with its live tally,
/// and a tap to vote. Single-choice only - the server accepts exactly one
/// vote per user per poll (a second vote replaces the first, it never adds
/// to it: see `store::polls::vote_poll`), so this widget carries no
/// multi-select state at all. Voting is refused server-side once the poll
/// is closed regardless of what this renders, so [poll]'s own `closed` flag
/// (never the client's clock) is what disables the tap here too.
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/emoji_catalog_provider.dart';
import 'message_text.dart';

/// Wide enough for a leading option's icon plus "100%" at [AppText.caption],
/// so every option's trailing column lines up regardless of digit count or
/// whether that particular row carries the leading glyph.
const double _percentColumnWidth = 72;

class PollView extends ConsumerWidget {
  const PollView({super.key, required this.poll, required this.onVote});

  final api.Poll poll;
  final ValueChanged<int> onVote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customEmoji = ref.watch(customEmojiIndexProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final canVote = !poll.closed;
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
                child: MessageBody(
                  content: poll.question,
                  knownUsernames: const {},
                  customEmoji: customEmoji,
                  baseStyle: AppText.body.copyWith(fontWeight: AppWeights.semi),
                ),
              ),
              // A closed poll used to say so only in the fine print below the options; this is the glance-able version.
              if (poll.closed) ...[
                const SizedBox(width: AppSpacing.s8),
                const AppBadge(variant: AppBadgeVariant.tag, label: 'Closed'),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.s8),
          for (final option in poll.options) ...[
            _PollOptionRow(
              option: option,
              totalVotes: poll.totalVotes,
              selected: poll.votedOption == option.position,
              leading: leadingPosition == option.position,
              onTap: canVote ? () => onVote(option.position) : null,
            ),
            const SizedBox(height: AppSpacing.s4),
          ],
          Text(
            _footerText(poll),
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
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
String _footerText(api.Poll poll) {
  if (poll.totalVotes == 0) {
    return poll.closed
        ? 'No one voted.'
        : 'No votes yet. Tap an option to vote.';
  }
  final count = poll.totalVotes;
  return '$count vote${count == 1 ? '' : 's'}';
}

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
class _PollOptionRow extends ConsumerStatefulWidget {
  const _PollOptionRow({
    required this.option,
    required this.totalVotes,
    required this.selected,
    required this.leading,
    required this.onTap,
  });

  final api.PollOption option;
  final int totalVotes;
  final bool selected;

  /// Whether this is the option [_leadingPosition] named. Never true for
  /// more than one option in the same poll.
  final bool leading;
  final VoidCallback? onTap;

  @override
  ConsumerState<_PollOptionRow> createState() => _PollOptionRowState();
}

class _PollOptionRowState extends ConsumerState<_PollOptionRow> {
  bool _focused = false;

  void _activate() {
    if (widget.onTap != null) widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final totalVotes = widget.totalVotes;
    final option = widget.option;
    final selected = widget.selected;
    final leading = widget.leading;
    final hasVotes = totalVotes > 0;
    final fraction = hasVotes ? option.votes / totalVotes : 0.0;
    final percent = (fraction * 100).round();
    final emphasised = selected || leading;
    // controlMd (34px) clears the pointer floor, not the touch one.
    final touch = AppTouchTargets.of(context);

    final tally = hasVotes
        ? '$percent percent, ${option.votes} vote${option.votes == 1 ? '' : 's'}'
        : 'no votes yet';

    return Semantics(
      button: widget.onTap != null,
      selected: selected,
      label:
          '${option.label}, $tally'
          '${selected ? ', your vote' : ''}'
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
              // Centred rather than a Stack's top-start default; see _PollOptionRow's own doc comment.
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
                    child: Row(
                      children: [
                        // The vote is never colour alone: a check beside the label carries it too, like presence elsewhere.
                        if (selected) ...[
                          Icon(
                            AppIcons.check,
                            size: AppSizes.icon16,
                            color: tokens.accentFill,
                          ),
                          const SizedBox(width: AppSpacing.s4),
                        ],
                        Expanded(
                          child: MessageBody(
                            content: option.label,
                            knownUsernames: const {},
                            customEmoji: ref.watch(customEmojiIndexProvider),
                            baseStyle: AppText.ui.copyWith(
                              fontWeight: emphasised
                                  ? AppWeights.semi
                                  : AppWeights.regular,
                            ),
                          ),
                        ),
                        // Hidden entirely rather than a silent "0%": every row shares one poll-level totalVotes, so this is all-or-nothing across the whole card.
                        if (hasVotes)
                          SizedBox(
                            width: _percentColumnWidth,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                // Never colour alone: the icon and the label's own semibold weight both carry "leading", not just this row reading lighter than its neighbour.
                                if (leading) ...[
                                  Icon(
                                    AppIcons.pollLeading,
                                    size: AppSizes.icon16,
                                    color: tokens.textSecondary,
                                  ),
                                  const SizedBox(width: AppSpacing.s4),
                                ],
                                Text(
                                  '$percent%',
                                  style: AppText.caption.copyWith(
                                    color: tokens.textSecondary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
