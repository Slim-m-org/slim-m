// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The identity half of a message row: the leading avatar or continuation
/// gutter, and the header line carrying the author name and timestamp.
///
/// Split out of `message_row.dart` to keep that file to the row's own
/// composition; `message_row_parts.dart` is its sibling for the smaller
/// pieces a row can carry beneath the body.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/display_preferences.dart';
import '../providers/user_profiles.dart';
import 'author_label.dart';
import 'author_profile_tap_target.dart';
import 'user_avatar.dart';

/// The avatar column's width, and therefore also the continuation gutter's:
/// the design's 40px message-row avatar, named once so both agree.
const double _avatarSize = AppAvatarSize.s40;

/// `HH:mm` or a 12-hour equivalent, following [use24Hour]. Fixed width
/// matters here: a grouped message puts its time in the avatar-wide gutter, and a
/// spelled-out "12:05 PM" wraps to two lines in it, which is why the 12-hour
/// form drops the leading zero and the space before its suffix ("12:05p")
/// rather than reusing `formatDateTime`'s longer one.
String formatMessageTime(int epochMs, {required bool use24Hour}) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final minute = dt.minute.toString().padLeft(2, '0');
  if (use24Hour) {
    return '${dt.hour.toString().padLeft(2, '0')}:$minute';
  }
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final suffix = dt.hour < 12 ? 'a' : 'p';
  return '$hour12:$minute$suffix';
}

const List<String> _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// The label a [DayDivider] carries: "Today" and "Yesterday" for the two days
/// a reader thinks of by name, an absolute date otherwise, and the year only
/// when it is not the current one. [now] is injectable so the relative days
/// are testable without depending on the wall clock.
String formatMessageDay(int epochMs, {DateTime? now}) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final today = now ?? DateTime.now();
  final thatDay = DateTime(dt.year, dt.month, dt.day);
  final todayDay = DateTime(today.year, today.month, today.day);
  final daysApart = todayDay.difference(thatDay).inDays;
  if (daysApart == 0) return 'Today';
  if (daysApart == 1) return 'Yesterday';
  final month = _monthNames[dt.month - 1];
  return dt.year == today.year
      ? '$month ${dt.day}'
      : '$month ${dt.day}, ${dt.year}';
}

/// The row's time slot, which is also its delivery state: the timestamp once
/// sent, a clock and "sending" while in flight, and a red "not sent" on
/// failure - full strength, because a failed message is still the author's
/// to act on (error grammar 01).
class MessageTimeMark extends ConsumerWidget {
  const MessageTimeMark({
    super.key,
    required this.message,
    this.compact = false,
  });

  final Message message;

  /// Glyph-only pending/failed marks, for the avatar-wide continuation gutter where
  /// a word cannot fit. The sent branch has no glyph fallback: no string
  /// `formatMessageTime` produces fits a mono face at the type scale's
  /// smallest legible size into the gutter, so the gutter positions this mark as
  /// an unconstrained overlay instead (see [MessageRowLeading]) rather than
  /// shrinking or wrapping it.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final mono = AppText.micro.copyWith(
      color: tokens.textSecondary,
      fontFamily: AppFonts.mono,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final Widget mark;
    if (message.failed) {
      mark = compact
          ? Icon(AppIcons.failed, size: 11, color: tokens.dangerText)
          : Text('not sent', style: mono.copyWith(color: tokens.dangerText));
    } else if (message.pending) {
      mark = compact
          ? Icon(AppIcons.clock, size: 11, color: tokens.textSecondary)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.clock, size: 11, color: tokens.textSecondary),
                const SizedBox(width: 4),
                Text('sending', style: mono),
              ],
            );
    } else {
      final use24Hour = watchUse24Hour(ref, context);
      // Always natural size (see [compact]): never scaled below the floor.
      mark = Text(
        formatMessageTime(message.createdAt, use24Hour: use24Hour),
        style: mono,
        maxLines: 1,
        softWrap: false,
      );
    }
    // Keyed on the state, never the text, so a minute tick never replays.
    final state = message.failed
        ? 'failed'
        : message.pending
        ? 'pending'
        : 'sent';
    return AnimatedSwitcher(
      duration: AppMotion.reduced(context, AppMotion.base),
      child: KeyedSubtree(key: ValueKey(state), child: mark),
    );
  }
}

/// The continuation gutter's delivery/timestamp mark, rendered as an
/// unconstrained overlay rather than laid out in flow.
///
/// No string [formatMessageTime] produces fits this column at the type
/// scale's smallest legible size (a mono face there advances roughly a
/// character-width per glyph, and even the shortest 12-hour form is five or
/// six characters), so the mark must never shrink below that floor or
/// resist the reader's text-scale setting just to make itself fit (PR
/// #1289 held a `FittedBox` version of this widget for exactly that: it
/// rendered as small as 6px and the setting did nothing in this gutter).
///
/// [Positioned] instead of a constrained child: left-aligned so it starts
/// where an avatar would and grows rightward into the 12px gap before the
/// message column, and past that into the column's own leading edge when
/// the format or the reader's text scale needs more room than the gap has.
/// That overlap is cosmetic and only while hovering; a [Positioned] child
/// never affects its [Stack]'s own size, so the message content beside it
/// never shifts.
///
/// The always-present [SizedBox.shrink] child is load-bearing, not
/// decorative: a [Stack] with only [Positioned] children and an unbounded
/// parent height has no way to size itself and asserts, so this gives it
/// one non-positioned child to size against instead.
class _ContinuationGutterMark extends StatelessWidget {
  const _ContinuationGutterMark({required this.message, required this.show});

  final Message message;
  final bool show;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const SizedBox.shrink(),
        if (show)
          Positioned(
            top: 3,
            left: 0,
            child: MessageTimeMark(message: message, compact: true),
          ),
      ],
    );
  }
}

class MessageRowLeading extends ConsumerWidget {
  const MessageRowLeading({
    super.key,
    required this.grouped,
    required this.message,
    required this.hovered,
  });

  final bool grouped;
  final Message message;

  /// The row's own hover state (mouse only - touch never sets this). Gates
  /// the continuation gutter's plain sent timestamp: Discord shows it only
  /// while hovering rather than pinning it to the left edge of every grouped
  /// line, and a finger that never hovers simply never shows it, which is the
  /// header time's job on the group's first message.
  final bool hovered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    if (grouped) {
      // The continuation gutter: no avatar; a delivery mark always shows, a plain sent time only on hover (see [hovered]).
      final showMark = message.pending || message.failed || hovered;
      return SizedBox(
        width: _avatarSize,
        child: _ContinuationGutterMark(message: message, show: showMark),
      );
    }

    final resolution = ref.watch(
      batchProfilesControllerProvider.select(
        (m) => authorResolution(m, message.authorId ?? ''),
      ),
    );

    if (resolution.profile?.isWebhook ?? false) {
      return Container(
        width: _avatarSize,
        height: _avatarSize,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border.all(color: tokens.borderSubtle),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Icon(
          AppIcons.code,
          size: AppSizes.icon20,
          color: tokens.textSecondary,
        ),
      );
    }

    // Decorative once there is nothing to open (the header beside it already
    // names the author, and without this every message was announced "Ada
    // Lovelace Ada Lovelace"); a real profile promotes it to a tap target.
    return AuthorProfileTapTarget(
      authorId: message.authorId,
      semanticLabel: 'View profile',
      decorativeWhenUnresolved: true,
      fingerTarget: true,
      child: UserAvatar(
        userId: message.authorId,
        name: authorLabelResolved(
          authorId: message.authorId,
          cachedDisplayName: message.authorDisplayName,
          resolution: resolution,
        ),
        size: _avatarSize,
      ),
    );
  }
}

class MessageRowHeader extends ConsumerWidget {
  const MessageRowHeader({
    super.key,
    required this.message,
    this.webhookUsername,
    this.editing = false,
  });

  final Message message;

  /// Adds the EDITING tag, so a row being edited says so on its first line.
  final bool editing;

  /// A webhook's per-post label, drawn as the name only while the author
  /// resolves to a webhook, so the Webhook badge always sits beside it.
  final String? webhookUsername;

  /// An author who has not resolved yet reads as neither a bot nor a
  /// webhook, so a badge is absent until the profile is known rather than
  /// appearing a moment after the name. A badge that pops in late is worse
  /// than one that is simply right once there is something to be right
  /// about.
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final resolution = ref.watch(
      batchProfilesControllerProvider.select(
        (m) => authorResolution(m, message.authorId ?? ''),
      ),
    );
    final isWebhook = resolution.profile?.isWebhook ?? false;
    final label = webhookUsername?.trim();
    final name = isWebhook && label != null && label.isNotEmpty
        ? label
        : authorLabelResolved(
            authorId: message.authorId,
            cachedDisplayName: message.authorDisplayName,
            resolution: resolution,
          );
    final isBot = resolution.profile?.isBot ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: AuthorProfileTapTarget(
              authorId: message.authorId,
              semanticLabel: '$name, view profile',
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ),
          ),
          if (isWebhook) ...[
            const SizedBox(width: AppSpacing.s8),
            const AppBadge(variant: AppBadgeVariant.tag, label: 'Webhook'),
          ],
          if (isBot) ...[
            const SizedBox(width: AppSpacing.s8),
            const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot'),
          ],
          const SizedBox(width: AppSpacing.s8),
          MessageTimeMark(message: message),
          if (editing) ...[
            const SizedBox(width: AppSpacing.s8),
            const AppBadge(variant: AppBadgeVariant.role, label: 'Editing'),
          ],
        ],
      ),
    );
  }
}
