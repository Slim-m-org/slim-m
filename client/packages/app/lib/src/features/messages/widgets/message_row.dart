// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One row in the message list: the avatar or continuation gutter, the
/// header line, the body, and everything that can follow it.
///
/// The avatar/gutter and header live in `message_row_identity.dart` and the
/// hover-reveal mechanism (shared with the emoji picker and the context menu)
/// lives in `hover_reveal.dart`, both split out to keep this file to the row's
/// own composition.
///
/// A left-to-right swipe on a phone-width row starts a reply; see
/// `swipe_to_reply.dart`.
///
/// The background fill answers `hovered || menuOpen` rather than `hovered`
/// alone: `menuOpen` is `HoverReveal`'s own signal that this row's context
/// menu is showing by any gesture, long press included, which `hovered`
/// cannot answer since a long press deliberately never pins it (see
/// `HoverReveal`'s own doc for why). AppListRow's own hover token is reused
/// rather than a second hover convention.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../settings/providers/display_density.dart';
import '../providers/message_extras.dart' show MessageExtras;
import '../../../routing/breakpoints.dart';

import 'continuation_marker.dart';
import '../../emoji/widgets/emoji_picker.dart';
import 'message_hover_toolbar.dart';
import '../../../widgets/hover_reveal.dart';
import 'message_context_menu.dart';
import 'message_row_identity.dart';
import 'message_row_callbacks.dart';
import 'message_row_column.dart';
import 'message_row_parts.dart';
import 'reactions_row.dart';
import 'swipe_to_reply.dart';
import 'message_text.dart';

/// One message, and optionally the "New" divider directly above it.
///
/// Grouping (dropping the avatar and header for a continuation) is decided by
/// the caller, which is what lets [ChannelScreen]'s tests exercise the rule
/// without needing a whole scrollable list.
class MessageRow extends ConsumerWidget {
  const MessageRow({
    super.key,
    required this.message,
    required this.grouped,
    required this.showNewDivider,
    this.dayLabel,
    required this.knownUsernames,
    this.knownRoleNames = const {},
    required this.callbacks,
    required this.actions,
    required this.editing,
    this.customEmoji = const {},
    this.extras = MessageExtras.empty,
    this.viewerIsCaller = false,
    this.replyTo,
    this.replyParentAdjacent = false,
    this.groupContinues = false,
  });

  final Message message;

  /// True for a continuation of the same author's previous message inside
  /// the density's grouping window: drops the avatar and header, and shows
  /// the time in the gutter instead.
  final bool grouped;

  final bool showNewDivider;

  /// A formatted calendar-day label ("Today", "Yesterday", "July 28, 2026")
  /// shown as a divider above this row when it is the first message of a new
  /// day. Null on every other row. Decided by the caller for the same reason
  /// [grouped] is: only the list knows what came before this row.
  final String? dayLabel;

  /// Lower-cased usernames the mention renderer treats as real. See
  /// [MessageBody].
  final Set<String> knownUsernames;

  /// See [MessageBody.knownRoleNames].
  final Set<String> knownRoleNames;

  /// The deployment's custom emoji, name to id. Resolves a `:shortcode:` in
  /// the body ([MessageBody]) and on a reaction chip ([ReactionsRow]) alike.
  final Map<String, String> customEmoji;

  /// Everything this row can ask its caller to do.
  final MessageRowCallbacks callbacks;

  /// What this row's context menu can do here: edit, delete, and pin/unpin,
  /// each gated by whatever the caller already knows about authorship and
  /// permissions.
  final MessageActions actions;

  /// True while this is the one row being edited inline. At most one row in
  /// a channel is ever true at once; [ChannelScreen] enforces that by
  /// keeping a single editing-message id, not this widget.
  final bool editing;

  /// What rides on this message beyond its text: reactions, attachments,
  /// embeds, a poll, an app, a call, the thread summary and a webhook's name.
  /// A new per-message field lands in `MessageExtras` and is read from here.
  final MessageExtras extras;

  /// Whether the reader is the one who placed `extras.call`. The same stored
  /// record reads as "missed call" to one side and "no answer" to the other,
  /// so this cannot be derived from the message: its author is always the
  /// caller.
  final bool viewerIsCaller;

  /// The message [message] replies to, resolved by the transcript, or null
  /// when [message] is not a reply at all or its parent could not be
  /// resolved. See `reply_quote.dart` for what null does and does not mean.
  final Message? replyTo;

  /// True when the quoted parent is the row directly above this one.
  final bool replyParentAdjacent;

  /// True when the next message continues this one's group, so a continuation
  /// marker runs on to it instead of ending here.
  final bool groupContinues;

  bool get _unsent => message.pending || message.failed;

  /// Exposed so a test can find the hover/menu-open background fill without
  /// depending on widget tree shape.
  static const Key hoverFillKey = Key('message_row_hover_fill');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = ref.watch(messageDensityControllerProvider);
    final groupSpacing = ref.watch(groupSpacingControllerProvider);
    final compact = LayoutClass.of(context) == LayoutClass.compact;
    final gutter = paneGutterOf(context);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final marker = grouped
        ? ref.watch(continuationMarkerControllerProvider)
        : ContinuationMarker.none;
    final headMarker = !grouped && groupContinues
        ? ref.watch(continuationMarkerControllerProvider)
        : ContinuationMarker.none;
    final marked = marker != ContinuationMarker.none;
    // Without a body there is no line to end on, so the gutter keeps the time.
    final inlineTime =
        marked && !_unsent && !editing && message.content.isNotEmpty;
    return HoverReveal(
      builder: (context, hovered, menuOpen, focusWithin) {
        final view = _RowView(
          tokens: tokens,
          density: density,
          groupSpacing: groupSpacing,
          compact: compact,
          gutter: gutter,
          marker: marker,
          headMarker: headMarker,
          inlineTime: inlineTime,
          hovered: hovered,
          menuOpen: menuOpen,
          focusWithin: focusWithin,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (dayLabel != null) DayDivider(label: dayLabel!),
            if (showNewDivider) const NewMessagesDivider(),
            SwipeToReply(
              enabled: compact && actions.canReply && !editing && !_unsent,
              onReply: actions.onReply,
              child: _contextRegion(context, view),
            ),
          ],
        );
      },
    );
  }

  Widget _contextRegion(BuildContext context, _RowView v) {
    return MessageContextMenuRegion(
      content: message.content,
      actions: actions,
      onAddReaction: () =>
          showEmojiPickerSheet(context, onSelect: callbacks.onPickReaction),
      onPickReaction: callbacks.onPickReaction,
      reactedEmoji: {
        for (final r in extras.reactions)
          if (r.reacted) r.emoji,
      },
      // A failed row is marked by a red hairline down its left edge
      // (error grammar 01) - the row itself stays at full strength,
      // because its content is still the author's to act on.
      child: Stack(
        // The toolbar's shadow spills past the row; clipping it would cut the blur.
        clipBehavior: Clip.none,
        children: [
          // Full-bleed, edge to edge; see this file's own doc comment.
          Positioned.fill(
            child: AnimatedContainer(
              key: MessageRow.hoverFillKey,
              duration: AppMotion.reduced(context, AppMotion.fast),
              curve: AppMotion.entrance,
              color: _fillColor(v),
            ),
          ),
          if (v.headMarker != ContinuationMarker.none)
            ContinuationHeadRail(
              geometry: ContinuationGeometry.of(
                context,
                gutter: v.gutter,
                density: v.density,
                groupSpacing: v.groupSpacing,
              ),
            ),
          if (v.marked)
            ContinuationRail(
              marker: v.marker,
              geometry: ContinuationGeometry.of(
                context,
                gutter: v.gutter,
                density: v.density,
              ),
              lastInGroup: !groupContinues,
            ),
          ConstrainedBox(
            // A row shorter than the toolbar would leave part of it painted but unhittable.
            constraints: BoxConstraints(
              minHeight: v.compact ? 0 : MessageHoverToolbar.height,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(border: _edgeBorder(v.tokens)),
              child: Padding(
                // Top-only: a bottom inset here doubled the next row's top inset.
                padding: EdgeInsets.fromLTRB(
                  v.gutter,
                  grouped
                      ? v.density.groupedRowGap
                      : v.density.rowGap + v.groupSpacing,
                  v.gutter,
                  0,
                ),
                child: _rowContents(v),
              ),
            ),
          ),
          // Outside layout, and never on compact, which reserves no clearance for it.
          if (_showToolbar(v))
            Positioned(
              top: 0,
              right: AppSizes.paneGutter,
              child: MessageHoverToolbar(
                actions: actions,
                onPickReaction: callbacks.onPickReaction,
              ),
            ),
        ],
      ),
    );
  }

  bool _lit(_RowView v) => v.hovered || v.menuOpen || editing;

  bool _showToolbar(_RowView v) =>
      !v.compact && (v.hovered || v.focusWithin) && !_unsent && !editing;

  Color _fillColor(_RowView v) {
    if (_lit(v)) return v.tokens.surfaceRaised;
    if (extras.mentionsMe) return v.tokens.accentSoft;
    return Colors.transparent;
  }

  Border _edgeBorder(AppTokens tokens) {
    if (message.failed) {
      return Border(left: BorderSide(color: tokens.dangerBorder, width: 2));
    }
    if (extras.mentionsMe) {
      return Border(left: BorderSide(color: tokens.accent, width: 2));
    }
    return const Border();
  }

  Color? _railBacking(_RowView v) {
    if (!v.marked) return null;
    return _lit(v) ? v.tokens.surfaceRaised : v.tokens.surfaceBase;
  }

  Widget _rowContents(_RowView v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MessageRowLeading(
          grouped: grouped,
          message: message,
          hovered: v.hovered && !v.inlineTime,
          railBacking: _railBacking(v),
        ),
        const SizedBox(width: AppSpacing.s12),
        Expanded(
          // Align loosens Expanded's tight width so the cap can
          // bite: without it the max was silently a no-op and body
          // text ran the full pane on any monitor.
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMessageColumnMax),
              child: _column(v),
            ),
          ),
        ),
      ],
    );
  }

  Widget _column(_RowView v) {
    return MessageRowColumn(
      message: message,
      grouped: grouped,
      compact: v.compact,
      editing: editing,
      actions: actions,
      knownUsernames: knownUsernames,
      knownRoleNames: knownRoleNames,
      customEmoji: customEmoji,
      callbacks: callbacks,
      extras: extras,
      replyTo: replyTo,
      replyParentAdjacent: replyParentAdjacent,
      viewerIsCaller: viewerIsCaller,
      hoverTime: v.inlineTime
          ? _InlineHoverTime(shown: v.hovered || v.menuOpen, message: message)
          : null,
    );
  }
}

/// What one build of a row resolved from the theme, settings and hover state.
class _RowView {
  const _RowView({
    required this.tokens,
    required this.density,
    required this.groupSpacing,
    required this.compact,
    required this.gutter,
    required this.marker,
    required this.headMarker,
    required this.inlineTime,
    required this.hovered,
    required this.menuOpen,
    required this.focusWithin,
  });

  final AppTokens tokens;
  final AppDensity density;
  final int groupSpacing;
  final bool compact;
  final double gutter;
  final ContinuationMarker marker;
  final ContinuationMarker headMarker;
  final bool inlineTime;
  final bool hovered;
  final bool menuOpen;
  final bool focusWithin;

  bool get marked => marker != ContinuationMarker.none;
}

/// The sent time at the end of a continuation's text. Laid out whether shown
/// or not, so hovering never rewraps the line.
class _InlineHoverTime extends StatelessWidget {
  const _InlineHoverTime({required this.shown, required this.message});

  final bool shown;
  final Message message;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    excluding: !shown,
    child: Opacity(
      opacity: shown ? 1 : 0,
      child: MessageTimeMark(message: message),
    ),
  );
}
