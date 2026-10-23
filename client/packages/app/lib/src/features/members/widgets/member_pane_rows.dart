// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rows the member pane is built out of: a group heading, a member, and
/// what an empty result says.
///
/// Split from `member_pane.dart` when the search box pushed it past the
/// review budget. The pane keeps what decides *which* members show; this
/// keeps what decides how one of them draws, and the two change for
/// different reasons.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/member_presence.dart';
import '../providers/module_badges.dart';
import '../providers/member_selection.dart';
import '../providers/presence_activity.dart';
import '../providers/presence_view.dart';
import '../providers/status_text.dart';
import 'member_profile.dart';
import 'module_row_badges.dart';
import '../../voice/providers/member_voice_channel.dart';
import 'member_voice_chip.dart';
import 'user_avatar.dart';

/// Test-only: how many times each member's row has actually run `build`,
/// keyed by user id. A rendered frame looks the same whether or not a
/// rebuild happened, so a rebuild-scoping test needs this to tell the two
/// apart. Reset with [debugResetMemberRowBuildCounts] between cases.
@visibleForTesting
final Map<String, int> debugMemberRowBuildCounts = {};

/// See [debugMemberRowBuildCounts].
@visibleForTesting
void debugResetMemberRowBuildCounts() => debugMemberRowBuildCounts.clear();

/// Below this row width a badge and a chip together crowd the name out.
const double _badgeAndChipMinRow = 300;

class MemberGroupLabel extends StatelessWidget {
  const MemberGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s8,
        AppRhythm.headingTop,
        AppSpacing.s8,
        AppRhythm.headingBottom,
      ),
      // A heading in its natural case, for the same reason the rail's are.
      child: Semantics(
        container: true,
        header: true,
        label: text,
        child: ExcludeSemantics(
          child: Text(
            text.toUpperCase(),
            style: AppText.label.copyWith(color: tokens.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// A row is muted (dimmed, per [AppListRow.muted]) only once fully offline;
/// away and do-not-disturb still read as present, matching the grouping
/// rule the pane applies.
///
/// A right-click reaches the same profile popover a tap already does, rather
/// than a second, narrower menu: every verb this row could offer already
/// lives there, gated exactly as it already is.
///
/// Presence is looked up here rather than passed in, and scoped to this
/// member's own id: `AppMemberPane` no longer watches the raw presence map,
/// so a `PresenceChanged` for someone else never reaches this row's build
/// at all, only the row for whoever actually changed.
class MemberRow extends ConsumerWidget {
  const MemberRow({
    required this.profile,
    required this.isSelf,
    this.channelId,
    this.sectionRoleId,
    super.key,
  });

  /// The channel whose roster this row is in.
  final String? channelId;

  final api.UserProfile profile;

  /// The role section this row sits under; its badge would only repeat the heading.
  final String? sectionRoleId;

  /// Nothing opens a DM with yourself: `POST /dms/{userId}` has no concept
  /// of one, and a self-conversation would just be a second copy of the
  /// notes only you would ever see.
  final bool isSelf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugMemberRowBuildCounts[profile.id] =
        (debugMemberRowBuildCounts[profile.id] ?? 0) + 1;
    final status = ref.watch(presenceForProvider(profile.id));
    // The roster snapshot, patched by memberProfileOverridesProvider if a live edit has since landed.
    final displayed =
        ref.watch(
          memberProfileOverridesProvider.select((m) => m[profile.id]),
        ) ??
        profile;
    final inVoice = ref.watch(
      memberVoiceChannelProvider(profile.id).select((c) => c != null),
    );
    final activity = ref.watch(memberActivityProvider(profile.id));
    final statusText = ref.watch(
      statusTextProvider((userId: profile.id, snapshot: profile.statusText)),
    );
    // One slot only in a 236px pane; bot beats a role, whose names are a tap away.
    final badge = _badgeLabel(displayed);
    ref.read(moduleBadgesProvider.notifier).request(profile.id);
    // Scoped to this member's own entry, and null while empty, so neither another member's badge nor a bare answer rebuilds this row.
    final moduleBadges = visibleModuleBadges(
      ref.watch(
        moduleBadgesProvider.select((m) {
          final own = m[profile.id];
          return own == null || own.isEmpty ? null : own;
        }),
      ),
    );

    // Scoped to this row's two facts: the set is a new object per toggle, so watching it rebuilds every row.
    final (selecting, selected) = ref.watch(
      memberSelectionProvider.select((s) => (s.active, s.contains(profile.id))),
    );
    final selectable = selecting && !isSelf;

    void open() => unawaited(
      showMemberProfile(context, profile: displayed, channelId: channelId),
    );
    void toggle() =>
        ref.read(memberSelectionProvider.notifier).toggle(profile.id);

    final tick = selecting
        ? Padding(
            padding: const EdgeInsets.only(left: AppSpacing.s8),
            child: _SelectionTick(selected: selected, enabled: selectable),
          )
        : null;

    final VoidCallback? onTap;
    if (selectable) {
      onTap = toggle;
    } else {
      onTap = selecting ? null : open;
    }

    // The chip is capped to a share of the row so a long role name ellipsizes there and never takes the member's own name.
    final row = LayoutBuilder(
      builder: (context, box) => AppListRow(
        // Taller than a channel row: a 28px avatar's corner status dot crops at the default height.
        height: 36,
        label: displayed.displayName,
        // What they are playing wins over a typed status; the card shows the activity.
        subtitle: personLine(activity, statusText),
        subtitleIcon: activity == null ? null : activityIcon(activity.kind),
        muted: status == AppPresence.offline,
        // On screen presence is only a dot and an opacity; this is how it is spoken.
        stateDescription: status.word,
        trailing: _trailing(
          badge,
          moduleBadges,
          displayed.isBot,
          box.maxWidth,
          inVoice: inVoice,
          chipTappable: !selecting,
        ),
        leading: UserAvatar.known(
          userId: profile.id,
          avatarUpdatedAt: displayed.avatarUpdatedAt,
          name: displayed.displayName,
          size: AppAvatarSize.s32,
          presence: true,
        ),
        selected: selected,
        // Opens the profile, which is where every verb about a member lives now.
        onTap: onTap,
      ),
    );

    return GestureDetector(
      onSecondaryTapDown: selecting ? null : (_) => open(),
      child: tick == null
          ? row
          : Row(
              children: [
                tick,
                Expanded(child: row),
              ],
            ),
    );
  }

  String? _badgeLabel(api.UserProfile displayed) {
    if (displayed.isBot) return 'Bot';
    if (displayed.roles.isEmpty) return null;
    final underOwnHeading =
        sectionRoleId != null && displayed.roleIds.firstOrNull == sectionRoleId;
    return underOwnHeading ? null : displayed.roles.first;
  }

  /// A narrow row that is in a call drops its role badge, which is one tap
  /// away on the card; a Bot tag stays, since it is what marks a bot.
  Widget? _trailing(
    String? label,
    List<api.ModuleBadge> moduleBadges,
    bool isBot,
    double rowWidth, {
    required bool inVoice,
    required bool chipTappable,
  }) {
    final badge = inVoice && !isBot && rowWidth < _badgeAndChipMinRow
        ? null
        : _badge(label, moduleBadges, isBot, rowWidth);
    if (!inVoice) return badge;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ConstrainedBox(
            // Beside a badge the chip yields, so the member's name keeps its room.
            constraints: BoxConstraints(
              maxWidth: rowWidth * (badge == null ? 0.35 : 0.25),
            ),
            child: MemberVoiceChip(
              userId: profile.id,
              endGap: badge != null,
              enabled: chipTappable,
            ),
          ),
        ),
        ?badge,
      ],
    );
  }

  Widget? _badge(
    String? label,
    List<api.ModuleBadge> moduleBadges,
    bool isBot,
    double rowWidth,
  ) {
    if (label == null && moduleBadges.isEmpty) return null;
    final variant = isBot ? AppBadgeVariant.tag : AppBadgeVariant.role;
    final chip = label == null
        ? null
        : AppBadge(variant: variant, label: label);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: rowWidth * 0.4),
      child: moduleBadges.isEmpty
          ? chip
          : LayoutBuilder(
              // A non-flex child is laid out unbounded, so cap the chip to the room itself.
              builder: (context, box) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (chip != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth),
                      child: chip,
                    ),
                  Flexible(child: ModuleRowBadges(moduleBadges)),
                ],
              ),
            ),
    );
  }
}

/// The pick/not-picked mark shown once selection mode is on, so an unselected
/// row states its own affordance instead of looking identical to a normal
/// browsing row - the member-pane analogue of `message_selectable.dart`'s own
/// tick for the transcript. Dimmed and non-interactive on its own for the
/// viewer's own row, which selection mode never offers.
class _SelectionTick extends StatelessWidget {
  const _SelectionTick({required this.selected, required this.enabled});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Container(
          width: AppSizes.icon16,
          height: AppSizes.icon16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? tokens.accentFill : Colors.transparent,
            border: Border.all(
              color: selected ? tokens.accentFill : tokens.borderStrong,
            ),
          ),
          child: selected
              ? Icon(AppIcons.check, size: 11, color: tokens.accentOn)
              : null,
        ),
      ),
    );
  }
}
