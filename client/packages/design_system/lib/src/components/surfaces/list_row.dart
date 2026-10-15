// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The workhorse row: the channel rail, the member list, and every other
/// single-line picker in the app are built from this one widget.
///
/// Ported from the source `ListRow.jsx`: a `position: relative` row with an
/// absolutely-positioned selection marker, `color`/`font-weight` driven by
/// `selected || unread`, and an unread dot that only appears when there is no
/// trailing content to carry that meaning instead.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_haptics.dart';
import '../../app_metrics.dart';
import '../../app_motion.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../../touch_targets.dart';
import 'list_row_label.dart';

/// Reads every [AppListRow] label below it in `text-primary` at rest, for a
/// settings card where each label names a control rather than a destination.
class AppStrongLabelScope extends InheritedWidget {
  const AppStrongLabelScope({required super.child, super.key});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppStrongLabelScope>() != null;

  @override
  bool updateShouldNotify(AppStrongLabelScope oldWidget) => false;
}

/// A single-line row: optional leading content, a label, an optional `meta`
/// caption, an optional trailing widget, and four states that combine freely.
///
/// - [selected]: a soft accent fill, plus a left accent marker unless an
///   [AppSelectionMarkerScope] above says an ancestor draws one. One of the
///   seven closed accent roles.
/// - [unread]: the source lifts both colour (`text-secondary` to
///   `text-primary`) and weight (regular to medium) for `selected || unread`
///   alike, so unread's *distinguishing* cue from selected is the dot, shown
///   only when [trailing] is absent (a trailing count badge already carries
///   the same meaning, so the dot would be redundant next to it). [muted]
///   suppresses this lift: a row that still passes [unread] while muted reads
///   no brighter than a read one, since mute is a request to be left alone
///   that an unread lift would otherwise fight. Which rows pass it at all is
///   the caller's rule rather than this component's - under
///   `docs/decisions/0049-per-channel-notification-behaviour.md` a muted
///   channel passes neither flag unless its reader hand-marked it unread.
/// - [mentioned]: a diamond in place of the unread dot's circle, painted in
///   [AppTokens.accentFill] instead of [AppTokens.textPrimary] - "unread
///   badge" and "mentions of you" are two of the seven closed accent roles
///   (`docs/decisions/0004-visual-identity-review.md`). Colour used to be the
///   only cue between them, which loses the distinction for anyone who
///   cannot separate the two hues; shape now carries it instead, and colour
///   only reinforces it. Implies [unread] visually (a mention is always
///   unread) but is read independently, so a caller need not also pass
///   `unread: true`; a row that is both still renders only the one diamond,
///   never a second dot alongside it.
/// - [muted]: dims the leading and trailing content to `opacity: 0.62`, but
///   deliberately not the label. The source dimmed the whole row, and doing
///   that here dragged an offline member's name below the AA contrast floor
///   (`textSecondary` is already near it); the icon and badge carry the
///   de-emphasis while the name stays readable. Not `textDisabled` either:
///   that means "not actionable", which a muted channel still is.
/// - [touch]: raises the row to [AppSizes.rowTouch]; nothing else about the
///   row changes. Left unset it follows [AppTouchTargets.of].
///
/// Keyboard focus draws a full-row outline in [AppTokens.focusRing]; selection
/// draws a left marker plus a fill in [AppTokens.accentSoft]. The two tokens
/// are byte-identical in every theme, so they are kept apart by shape rather
/// than colour: a row can be selected, unread, and focused all at once with
/// every state still legible (see the combined case in the test file).
/// Marks a subtree whose selection marker is drawn by an ancestor, so the
/// rows inside it do not draw their own.
///
/// The channel rail owns one accent bar that slides between rows, which is
/// the whole point of it travelling. An [AppListRow] inside that layer still
/// wants everything else `selected` gives it - the soft fill, the weight -
/// and wants exactly one bar, not its own on top of the layer's. Without
/// this the rail drew two, and had since the travelling marker landed.
class AppSelectionMarkerScope extends InheritedWidget {
  const AppSelectionMarkerScope({required super.child, super.key});

  /// Whether something above [context] is already drawing the marker.
  static bool ownedAbove(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppSelectionMarkerScope>() !=
      null;

  @override
  bool updateShouldNotify(AppSelectionMarkerScope oldWidget) => false;
}

class AppListRow extends StatefulWidget {
  const AppListRow({
    super.key,
    required this.label,
    this.leading,
    this.meta,
    this.trailing,
    this.trailingExtra,
    this.selected = false,
    this.unread = false,
    this.mentioned = false,
    this.muted = false,
    this.touch,
    this.height,
    this.onTap,
    this.focusNode,
    this.semanticLabel,
    this.stateDescription,
    this.subtitle,
    this.subtitleIcon,
  });

  final String label;
  final Widget? leading;

  /// A short secondary caption (a timestamp, a role name), rendered in
  /// `text-secondary` regardless of the row's other states.
  final String? meta;
  final Widget? trailing;

  /// A second line under [label] (a custom status), in a smaller, dimmer
  /// style, single line with its own ellipsis. Turns this row from one line
  /// into two: the leading avatar stays vertically centred across both, per
  /// the Discord/Slack pattern this replaces a detached caption block with.
  /// Null keeps the row exactly as single-line as it always was.
  final String? subtitle;

  /// A small glyph before [subtitle], for a line that names an activity
  /// rather than a typed status. Ignored without a subtitle.
  final IconData? subtitleIcon;

  /// A control rendered after [trailing] (or the unread dot it falls back
  /// to), still inside the same tinted [AnimatedContainer] the row's hover
  /// and selection paint into. This is where a per-row overflow action
  /// belongs: painted as a plain sibling of this widget instead, the row's
  /// own press/hover highlight stops before it and the row reads as two
  /// pieces rather than one.
  final Widget? trailingExtra;
  final bool selected;
  final bool unread;
  final bool mentioned;
  final bool muted;

  /// Null means "whatever this subtree is at", read from [AppTouchTargets].
  final bool? touch;

  /// Raises the row above its derived height. The member list uses this: its
  /// rows pair a larger avatar with a status dot on the corner, which crops at
  /// the channel-row default. It is a floor rather than an override, so a
  /// touch layout is never shrunk below its hit target by a caller.
  final double? height;
  final VoidCallback? onTap;

  /// Exposed for callers that need to drive focus programmatically (a
  /// command palette moving focus down a result list); the source has no
  /// equivalent since a static mockup cannot express that, but a controllable
  /// node is ordinary Flutter widget hygiene and has no visual effect on its
  /// own.
  final FocusNode? focusNode;

  /// Overrides the accessible label entirely (state suffixes below are still
  /// appended). Falls back to [label].
  final String? semanticLabel;

  /// Announced after the label, for state a sighted reader gets from the row's
  /// appearance and nobody else gets at all.
  ///
  /// [muted] deliberately announces nothing on its own: it is a wholesale
  /// visual de-emphasis with no single meaning, and its only caller uses it for
  /// an offline member, who was being announced as "muted" as a result.
  final String? stateDescription;

  /// Exposed so a test can find the left selection marker without depending
  /// on widget tree shape.
  static const Key selectionMarkerKey = Key('app_list_row_selection_marker');

  /// Exposed so a test can find the unread dot without depending on colour.
  static const Key unreadDotKey = Key('app_list_row_unread_dot');

  /// [unreadDotKey]'s counterpart for [mentioned]: a diamond rather than a
  /// circle, painted in accent fill, so a test - or a viewer who cannot
  /// separate the two hues - can tell the two apart without reading colour.
  static const Key mentionDotKey = Key('app_list_row_mention_dot');

  /// The height a row built here takes, for a sibling that must line up with
  /// one rather than centre against the taller column it sits in.
  ///
  /// Grows past the design's own fixed row height once Dynamic Type scales
  /// the label past what that height can hold, rather than clipping it
  /// harder into the ellipsis - "row height must never animate" is about
  /// motion, never about staying fixed at every text scale, and this is
  /// still a plain, non-animated value read fresh on every build. Never
  /// shrinks below the fixed height, which stays the floor at the
  /// platform's default text size.
  ///
  /// [hasSubtitle] adds room for the second line [subtitle] renders, the same
  /// way Dynamic Type adds room for a taller label: a static value, read
  /// fresh on every build, never animated in.
  static double heightFor(
    BuildContext context, {
    bool? touch,
    double? min,
    bool hasSubtitle = false,
  }) {
    final density = touch ?? AppTouchTargets.of(context);
    final base = math.max(
      density ? AppSizes.rowTouch : AppSizes.rowPointer,
      min ?? 0,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final scaledLabelHeight =
        textScaler.scale(AppText.ui.fontSize!) * AppText.ui.height!;
    if (!hasSubtitle) {
      return math.max(base, scaledLabelHeight + AppSpacing.s8);
    }
    final scaledSubtitleHeight =
        textScaler.scale(AppText.caption.fontSize!) * AppText.caption.height!;
    final twoLineHeight = scaledLabelHeight +
        AppSpacing.s4 +
        scaledSubtitleHeight +
        AppSpacing.s8;
    return math.max(base, twoLineHeight);
  }

  @override
  State<AppListRow> createState() => _AppListRowState();
}

class _AppListRowState extends State<AppListRow> {
  bool _hovered = false;
  bool _focused = false;

  /// A finger has no hover, so on a phone this is the only sign a tap landed
  /// before its action runs. Shown as the same raised fill hover uses, but it
  /// appears the instant the finger touches down rather than on release.
  bool _pressed = false;

  /// The side of the square [_dotFor] rotates into a diamond, chosen so the
  /// rotated bounding box lands exactly on the unread dot's 6x6 footprint -
  /// neither shape reflows the row's trailing slot when the other replaces it.
  static const double _diamondSide = 6 * math.sqrt1_2;

  /// Unread's circle and a mention's diamond, both boxed to the same 6x6
  /// footprint regardless of shape. See [AppListRow.mentioned] for why this
  /// exists: colour alone did not survive greyscale.
  static Widget _dotFor({required bool mentioned, required Color color}) {
    if (!mentioned) {
      return DecoratedBox(
        key: AppListRow.unreadDotKey,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppRadii.full),
        ),
        child: const SizedBox(width: 6, height: 6),
      );
    }
    return SizedBox(
      width: 6,
      height: 6,
      child: Center(
        child: Transform.rotate(
          angle: math.pi / 4,
          child: DecoratedBox(
            key: AppListRow.mentionDotKey,
            decoration: BoxDecoration(color: color),
            child: const SizedBox(width: _diamondSide, height: _diamondSide),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = widget.touch ?? AppTouchTargets.of(context);
    final rowHeight = AppListRow.heightFor(
      context,
      touch: touch,
      min: widget.height,
      hasSubtitle: widget.subtitle != null,
    );

    // `mentioned` joins `selected`/`unread`'s lift; `muted` suppresses the unread half of it, since only a mention breaks through mute.
    final emphasised =
        widget.selected || widget.mentioned || (widget.unread && !widget.muted);
    final labelStyle = AppText.ui.copyWith(
      color: emphasised || AppStrongLabelScope.of(context)
          ? tokens.textPrimary
          : tokens.textSecondary,
      fontWeight: emphasised ? AppWeights.medium : AppWeights.regular,
    );

    Widget? trailingContent = widget.trailing;
    // The dot pops in (scale and fade) to confirm the state change, then sits
    // still: the motion spec forbids it ever pulsing while resting.
    trailingContent ??= (widget.unread || widget.mentioned)
        ? TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: AppMotion.reduced(context, AppMotion.base),
            curve: AppMotion.entrance,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
            ),
            child: _dotFor(
              mentioned: widget.mentioned,
              color: widget.mentioned ? tokens.accentFill : tokens.textPrimary,
            ),
          )
        : null;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          spacing: AppSpacing.s8,
          children: [
            // Excluded for the same reason the label below is: an avatar names
            // itself, so a member row announced its name twice.
            if (widget.leading != null)
              ExcludeSemantics(
                child: Opacity(
                  opacity: widget.muted ? 0.62 : 1,
                  child: widget.leading!,
                ),
              ),
            Expanded(
              // Excluded because the Semantics wrapper below already names this
              // row; without it a screen reader announces "general, general".
              child: ExcludeSemantics(
                child: AppListRowLabel(
                  label: widget.label,
                  subtitle: widget.subtitle,
                  subtitleIcon: widget.subtitleIcon,
                  labelStyle: labelStyle,
                ),
              ),
            ),
            if (widget.meta != null)
              // Sized to its text and capped, not Flexible: a Flexible beside the
              // Expanded label split the free space in half and floated the
              // value mid-row instead of against the trailing edge.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * 0.5),
                child: Text(
                  widget.meta!,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ),
            if (trailingContent != null)
              Opacity(
                opacity: widget.muted ? 0.62 : 1,
                child: trailingContent,
              ),
            if (widget.trailingExtra != null) widget.trailingExtra!,
          ],
        ),
      ),
    );

    // Two fill layers on the motion spec's two clocks: the selection tint
    // fades over the panel duration while hover shifts at press speed, and
    // one AnimatedContainer cannot serve both.
    // Height on a plain box: density is layout, not motion, and animating it
    // smears a settings change. The AnimatedContainer carries only the tint.
    final visual = SizedBox(
      height: rowHeight,
      child: AnimatedContainer(
        duration: AppMotion.reduced(context, AppMotion.base),
        curve: AppMotion.entrance,
        decoration: BoxDecoration(
          color: widget.selected ? tokens.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        foregroundDecoration: _focused
            ? BoxDecoration(
                border: Border.all(color: tokens.focusRing, width: 2),
                borderRadius: BorderRadius.circular(AppRadii.control),
              )
            : null,
        child: Stack(
          // Expand, or the row's content takes its intrinsic height and a Stack
          // aligns it top-start: the icon, label and unread dot all sat above
          // the centre of a 30pt row, and higher still on a 44pt touch one.
          fit: StackFit.expand,
          children: [
            AnimatedContainer(
              duration: AppMotion.reduced(context, AppMotion.fast),
              curve: AppMotion.entrance,
              decoration: BoxDecoration(
                color: !widget.selected && (_pressed || _hovered)
                    ? tokens.surfaceRaised
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ),
            content,
            if (widget.selected && !AppSelectionMarkerScope.ownedAbove(context))
              Positioned(
                left: 0,
                top: 5,
                bottom: 5,
                width: 2,
                // Grows from centre (scaleY 0 to 1) as selection arrives, per
                // the motion spec; a tween rather than an implicit container so
                // the growth also plays on the frame the marker first mounts.
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: AppMotion.reduced(context, AppMotion.base),
                  curve: AppMotion.entrance,
                  builder: (context, t, child) => Transform.scale(
                    scaleY: t,
                    child: child,
                  ),
                  child: DecoratedBox(
                    key: AppListRow.selectionMarkerKey,
                    decoration: BoxDecoration(
                      color: tokens.accentFill,
                      // A literal 2px in the source rather than an AppRadii
                      // step; ported as-is rather than rounded to a token.
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    final semanticParts = <String>[
      widget.semanticLabel ?? widget.label,
      if (widget.subtitle != null) widget.subtitle!,
      if (widget.mentioned) 'mentioned' else if (widget.unread) 'unread',
      if (widget.stateDescription != null) widget.stateDescription!,
    ];

    return Semantics(
      // Its own node, not an annotation merged into whatever encloses it: the
      // rail's rows were landing in a screen-sized ancestor and vanishing,
      // which left the whole channel list unreachable to a screen reader.
      container: true,
      label: semanticParts.join(', '),
      button: widget.onTap != null,
      selected: widget.selected,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        mouseCursor:
            widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: widget.onTap == null
            ? const <Type, Action<Intent>>{}
            : <Type, Action<Intent>>{
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) => widget.onTap!(),
                ),
              },
        child: GestureDetector(
          onTapDown: widget.onTap == null
              ? null
              : (_) => setState(() => _pressed = true),
          onTapUp: widget.onTap == null
              ? null
              : (_) => setState(() => _pressed = false),
          onTapCancel: widget.onTap == null
              ? null
              : () => setState(() => _pressed = false),
          onTap: widget.onTap == null
              ? null
              : () {
                  AppHaptics.selection();
                  widget.onTap!();
                },
          // Muted dims the leading and trailing content only, never the
          // label: textSecondary is already near the AA floor, and scaling
          // the whole row's opacity dragged offline member names to 3.7:1.
          child: visual,
        ),
      ),
    );
  }
}
