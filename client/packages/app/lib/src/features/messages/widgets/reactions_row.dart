// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The reactions row under a message: one chip per distinct emoji, arriving
/// with a pop and leaving with the same pop in reverse, played in place.
///
/// Split out of `message_row_parts.dart` in the change that gave removal an
/// exit animation, which pushed that file past the 500-line hard ceiling.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../emoji/widgets/custom_emoji_image.dart';
import 'reaction_chip_who.dart';
import '../../emoji/providers/standard_emoji.dart';

/// 16, not the 13 the chip's text glyph uses: 13 is a font size, and an emoji
/// face draws well inside its em box while an image fills whatever box it gets.
const double _reactionEmojiSize = 16;

/// Every chip in [ReactionsRow]'s [Wrap] is a [FocusableTapTarget], which
/// reserves [focusRingGap] plus [focusRingWidth] of invisible margin on
/// every side for its own focus ring - present whether or not the ring is
/// ever drawn. A plain [AppSpacing.s4] step between two such chips therefore
/// painted as three stacked reservations (one chip's margin, the spacing,
/// the next chip's margin), not the one step it names.
///
/// This cancels only the spacing itself - the one value anyone actually
/// chose - leaving the two chips' own ring margins as the entire visible
/// gap. It deliberately stops at zero rather than going negative: a
/// negative value would pull adjacent chips' invisible hit boxes into
/// overlapping, and since each box is opaque to a tap regardless of what is
/// painted under it, that would erase the dead zone that currently exists
/// between two chips - every point in the visible gap would then resolve
/// to reacting on one chip or the other, where today it does nothing.
/// Zero keeps the boxes exactly abutting rather than overlapping, so that
/// dead zone shrinks to nothing rather than being eliminated.
const double _reactionChipSpacing =
    AppSpacing.s4 - (focusRingGap + focusRingWidth);

/// One chip per distinct emoji already on the message (real counts, and
/// [api.ReactionSummary.reacted] driving the active state). There is no
/// add-reaction control at rest: [MessageRow]'s hover toolbar carries it on a
/// pointer and the long-press menu's quick row on touch (desktop-vs-mobile
/// rule 3), and tapping a chip toggles the viewer's own reaction of it.
/// Tapping an existing chip calls [onReactionTap] with that summary; the
/// caller decides whether that means adding or removing based on whether it
/// was already active.
///
/// A reaction key is not always a codepoint. The server keys a reaction on
/// whatever short string it is given, so one of the deployment's own emoji
/// rides there as its `:shortcode:` and is drawn here through [customEmoji],
/// the same index a message body resolves against.
/// Opts out of the transcript's `SelectionArea`: inside it a chip's emoji and
/// count were selectable text, so hovering showed the I-beam over a button and
/// a drag selected the emoji. A chip is a control, not prose.
class ReactionsRow extends StatefulWidget {
  const ReactionsRow({
    super.key,
    required this.reactions,
    required this.onReactionTap,
    this.messageId,
    this.customEmoji = const {},
  });

  /// The message these chips sit under. With it, holding a chip (or
  /// right-clicking it) lists who left that reaction; without it the chips are
  /// plain toggles.
  final String? messageId;

  final List<api.ReactionSummary> reactions;
  final ValueChanged<api.ReactionSummary> onReactionTap;

  /// The deployment's custom emoji, lower-cased name to id. Empty while the
  /// set is loading or unfetchable, which leaves a shortcode reaction as the
  /// literal text it already was, exactly as a message body degrades.
  final Map<String, String> customEmoji;

  /// Renders existing reactions and nothing else.
  ///
  /// The add-a-reaction control used to live here, revealed on hover, and
  /// that is what made rows jump: an unreacted message rendered nothing, so
  /// hovering swapped absent for present and grew the row, moving the whole
  /// log under the pointer. It lives in [MessageRow]'s hover overlay now,
  /// outside layout entirely.
  ///
  /// The reasoning that put it here was sound and still holds - a permanent
  /// add-button under every message costs a row of vertical space each and
  /// turns a quiet list into a grid of identical glyphs. That is why the fix
  /// is an overlay rather than reserving the space: reserving it would buy
  /// back exactly the cost this avoided.
  ///
  /// Pulled tight against the body above by [AppSpacing.s4], the closest step
  /// to the few pixels of line-height leftover a real phone showed at a flush
  /// 0. The row's own box is that much shorter, so no dead space is left below.
  @override
  State<ReactionsRow> createState() => _ReactionsRowState();
}

class _ReactionsRowState extends State<ReactionsRow> {
  /// A chip whose reaction just left the list stays mounted in place while a
  /// reverse pop plays, so removal lands the way arrival already did; keyed
  /// by emoji and dropped the moment the exit completes. The entrance's
  /// [_ChipPop] cannot cover this half: an unmounted widget has nothing left
  /// on screen to animate, the same structural gap the menu portals had.
  final Map<String, api.ReactionSummary> _exiting = {};

  /// The emojis in on-screen order, so an exiting chip fades where it stood
  /// rather than teleporting to the end of the row first.
  List<String> _order = const [];

  @override
  void initState() {
    super.initState();
    _order = [for (final r in widget.reactions) r.emoji];
  }

  @override
  void didUpdateWidget(ReactionsRow old) {
    super.didUpdateWidget(old);
    final current = {for (final r in widget.reactions) r.emoji};
    if (!AppMotion.isReduced(context)) {
      for (final r in old.reactions) {
        if (!current.contains(r.emoji)) _exiting[r.emoji] = r;
      }
    }
    _exiting.removeWhere((emoji, _) => current.contains(emoji));
    _order = [
      for (final e in _order)
        if (current.contains(e) || _exiting.containsKey(e)) e,
      for (final r in widget.reactions)
        if (!_order.contains(r.emoji)) r.emoji,
    ];
  }

  Widget _chip(api.ReactionSummary reaction, {required bool exiting}) {
    final customId = customEmojiIdFor(reaction.emoji, widget.customEmoji);
    final chip = AppChip.reaction(
      // The deployment's own emoji wins a name clash; the key stays the tap target.
      emoji: customId == null
          ? standardEmojiFor(reaction.emoji) ?? reaction.emoji
          : reaction.emoji,
      count: reaction.count,
      active: reaction.reacted,
      glyph: switch (customId) {
        final String id => CustomEmojiImage(
          emojiId: id,
          size: MediaQuery.textScalerOf(context).scale(_reactionEmojiSize),
        ),
        null => null,
      },
      onTap: exiting ? null : () => widget.onReactionTap(reaction),
    );
    final messageId = widget.messageId;
    if (exiting || messageId == null) return chip;
    return ReactionChipWho(
      messageId: messageId,
      reaction: reaction,
      customEmoji: widget.customEmoji,
      child: chip,
    );
  }

  @override
  Widget build(BuildContext context) {
    final live = {for (final r in widget.reactions) r.emoji: r};
    if (live.isEmpty && _exiting.isEmpty) return const SizedBox.shrink();

    return SelectionContainer.disabled(
      child: _PullUp(
        by: AppSpacing.s4,
        child: Wrap(
          spacing: _reactionChipSpacing,
          runSpacing: _reactionChipSpacing,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Keyed by emoji: an arriving chip pops once, and never replays.
            for (final emoji in _order)
              if (live[emoji] case final reaction?)
                _ChipPop(
                  key: ValueKey('reaction-$emoji'),
                  child: _chip(reaction, exiting: false),
                )
              else if (_exiting[emoji] case final reaction?)
                _ChipExit(
                  key: ValueKey('reaction-exit-$emoji'),
                  onDone: () {
                    if (!mounted) return;
                    setState(() {
                      _exiting.remove(emoji);
                      _order = [..._order]..remove(emoji);
                    });
                  },
                  child: _chip(reaction, exiting: true),
                ),
          ],
        ),
      ),
    );
  }
}

/// Paints [child] [by] above where it was laid out and reports a box [by]
/// shorter, so the pull is not paid for as dead space under the child.
class _PullUp extends SingleChildRenderObjectWidget {
  const _PullUp({required this.by, required super.child});

  final double by;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPullUp(by);

  @override
  void updateRenderObject(BuildContext context, _RenderPullUp renderObject) {
    renderObject.by = by;
  }
}

class _RenderPullUp extends RenderShiftedBox {
  _RenderPullUp(this._by) : super(null);

  double _by;

  set by(double value) {
    if (value == _by) return;
    _by = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    final pull = _by.clamp(0.0, child.size.height);
    (child.parentData! as BoxParentData).offset = Offset(0, -pull);
    size = constraints.constrain(
      Size(child.size.width, child.size.height - pull),
    );
  }
}

/// A one-shot pop for a chip that just appeared: scale .85 to 1 with a fade,
/// the motion spec's confirmation entrance. Mount-only, so a rebuild of an
/// existing chip never replays it.
class _ChipPop extends StatelessWidget {
  const _ChipPop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: AppMotion.reduced(context, AppMotion.pop),
    curve: AppMotion.entrance,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
    ),
    child: child,
  );
}

/// [_ChipPop] in reverse, for a chip whose reaction was just removed: plays
/// once on mount and reports [onDone] so its owner can drop the remains.
class _ChipExit extends StatelessWidget {
  const _ChipExit({super.key, required this.onDone, required this.child});

  final VoidCallback onDone;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 1, end: 0),
    duration: AppMotion.reduced(context, AppMotion.pop),
    curve: AppMotion.exit,
    onEnd: onDone,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
    ),
    // The remains are visual only: they must not eat a tap mid-exit.
    child: IgnorePointer(child: child),
  );
}
