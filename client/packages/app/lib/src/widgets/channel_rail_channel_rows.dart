// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's channel rows: the kebab pairing (see `channel_row_menu.dart`
/// for the menu it and the row's own right-click/long-press both open), the
/// voice row and the participant strip beneath it.
///
/// Split out of `channel_rail_sections.dart` when that file crossed the
/// 300-line review budget; the sections there own layout and permissions,
/// these own one row each.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/channel_notification_overrides_controller.dart';
import '../providers/unread_indicator_rules.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_roster.dart';
import 'channel_kind_icon.dart';
import 'channel_move.dart';
import 'channel_row_menu.dart';
import 'context_menu_region.dart';
import 'rail_voice_participants.dart';
import 'voice_channel_tap.dart';

/// Pairs a channel row with its kebab, handed to
/// [AppListRow.trailingExtra] (via [row]'s own builder) rather than composed
/// as a plain sibling: a sibling sits outside the tinted container the row's
/// hover and press highlight paints into, so the highlight visibly stopped
/// short of the kebab and the row read as two pieces.
class ManagedChannelRow extends StatefulWidget {
  const ManagedChannelRow({
    super.key,
    required this.canManage,
    required this.reorderable,
    this.menuKey,
    this.move,
    required this.channel,
    required this.row,
  });

  final bool canManage;
  final Channel channel;

  /// Whether this render actually wraps the row in
  /// `ReorderableDelayedDragStartListener` - see `channel_rail_reorder.dart`'s
  /// own doc comment. True withholds the context menu's own long press,
  /// which would otherwise race the drag listener for the same held-press
  /// gesture and win, leaving the drag unreachable; a right-click and the
  /// keyboard route are both unaffected either way.
  final bool reorderable;

  /// Lets the rail open this row's menu when a held press is released without
  /// moving the row (`channel_rail_reorder.dart`).
  final GlobalKey<ContextMenuRegionState>? menuKey;

  /// The non-gesture way to reorder, offered in the menu to a manager.
  final ChannelMoveActions? move;

  /// Builds the row given the kebab to place in its trailing slot, or null
  /// when [canManage] is false. Passed through unconditionally so the row
  /// itself decides where to put it (`AppListRow.trailingExtra`, alongside
  /// whatever [AppListRow.trailing] or the unread dot already occupies).
  final Widget Function(Widget? kebab) row;

  @override
  State<ManagedChannelRow> createState() => _ManagedChannelRowState();
}

class _ManagedChannelRowState extends State<ManagedChannelRow> {
  bool _hovered = false;
  bool _kebabFocused = false;

  /// Reached by the kebab too (see [build]'s `onPressed`), so a tap there
  /// opens the exact same menu a right-click or long-press would rather than
  /// the separate "manage" sheet the kebab used to jump to directly.
  late final GlobalKey<ContextMenuRegionState> _menuKey =
      widget.menuKey ?? GlobalKey<ContextMenuRegionState>();

  /// This row's own context, not the one `itemsBuilder` hands in: on a
  /// compact width the menu is a sheet pushed straight onto the root
  /// navigator, so its context cannot resolve `GoRouterState.of` (the same
  /// cause `pinned_messages_sheet.dart`'s own doc comment names), while this
  /// row's `context` sits in the routed tree either way.
  List<Widget> _menuItems(BuildContext context, VoidCallback close) =>
      channelRowMenuItems(
        this.context,
        close,
        widget.channel,
        widget.canManage,
        move: widget.move,
      );

  @override
  Widget build(BuildContext context) {
    if (!widget.canManage) {
      return ContextMenuRegion(
        itemsBuilder: _menuItems,
        ownsFocusNode: false,
        child: widget.row(null),
      );
    }
    final enableLongPress = !widget.reorderable;
    final touch = AppTouchTargets.of(context);
    if (touch) {
      // A phone row is icon, name and badge; options open from the held press.
      return ContextMenuRegion(
        key: _menuKey,
        itemsBuilder: _menuItems,
        ownsFocusNode: false,
        enableLongPress: enableLongPress,
        child: Semantics(
          onLongPress: () => _menuKey.currentState?.open(),
          child: widget.row(null),
        ),
      );
    }
    // Mirrors _SectionLabel's own trailing inset so this glyph and the
    // section's add glyph share a right edge; both are AppIconButtonSize.sm.
    const trailingPad = 4.0;

    // A persistent kebab on every row adds a column of noise to the calmest
    // part of the shell, so a pointer reveals it on row hover (or when tab
    // reaches it, so a keyboard user never focuses something invisible). The
    // slot keeps its width either way; nothing reflows.
    final shown = _hovered || _kebabFocused;
    final kebab = Padding(
      padding: EdgeInsets.only(right: trailingPad),
      child: SizedBox(
        height: AppListRow.heightFor(context),
        child: Center(
          child: Focus(
            skipTraversal: true,
            canRequestFocus: false,
            onFocusChange: (v) => setState(() => _kebabFocused = v),
            child: AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: AppMotion.reduced(context, AppMotion.fast),
              // Hidden from the eye is not hidden from a screen reader: the
              // manage action must stay in the semantics tree while unhovered.
              alwaysIncludeSemantics: true,
              child: AppIconButton(
                icon: AppIcons.moreVertical,
                semanticLabel: 'Manage ${widget.channel.name}',
                size: AppIconButtonSize.sm,
                onPressed: () => _menuKey.currentState?.open(),
                // The row's own tint already covers this kebab; see the param's own doc.
                suppressOwnHoverFill: true,
              ),
            ),
          ),
        ),
      ),
    );
    // Inside the row's trailing slot, so no combined height to float against.
    return ContextMenuRegion(
      key: _menuKey,
      itemsBuilder: _menuItems,
      ownsFocusNode: false,
      enableLongPress: enableLongPress,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: widget.row(kebab),
      ),
    );
  }
}

/// `unread` and `mentioned` run the same [unreadIndicatorFor] the rail's text
/// rows do: a voice channel has its own transcript and composer now
/// (`screens/voice_text_pane.dart`), so unread text - and a mention in it, and
/// a notification override over both - means the same thing here it does
/// anywhere else. `unread` used to read `inCall` instead, which left the dot
/// permanently lit for whoever was in the call and blind to actual unread
/// text; being in the call already has its own cue, the accented mic icon
/// below, so it does not need to borrow this one too.
///
/// The mute glyph the text row draws has no slot to take here - the
/// participant count already holds it - so a muted voice channel reads as
/// muted from [AppListRow.muted]'s own dimming alone. A channel that joins
/// muted carries no glyph on its row: that is a default the channel's
/// settings own, and a member meets it on the join screen.
class VoiceChannelRow extends ConsumerWidget {
  const VoiceChannelRow({
    super.key,
    required this.channel,
    required this.selected,
    this.trailingExtra,
  });

  final Channel channel;
  final bool selected;

  /// The kebab [ManagedChannelRow] hands down, rendered in the same
  /// trailing slot as the participant count so both sit inside the row's
  /// own press/hover highlight rather than beside it.
  final Widget? trailingExtra;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Watched here, not by the section laying out every row, narrowed to state/channelId alone.
    final (voiceState, voiceChannelId) = ref.watch(
      voiceFlagsProvider.select((f) => (f.state, f.channelId)),
    );
    final inCall =
        voiceState == VoiceSessionState.connected &&
        voiceChannelId == channel.id;
    final iconColor = inCall
        ? tokens.accent
        : tokens.textSecondary.withValues(alpha: 0.7);
    final override = ref.watch(
      channelNotificationOverridesProvider.select(
        (s) => s.overrideFor(channel.id),
      ),
    );
    final indicator = unreadIndicatorFor(
      channelOverride: override,
      isDm: false,
      unread: channel.cursor > channel.lastReadSeq,
      mentioned: channel.mentionedSeq > channel.lastReadSeq,
      manuallyUnread: channel.manuallyUnread ?? false,
    );

    // A joined call already has this live; an unjoined one polls for it below.
    final participants = inCall
        ? ref.watch(voiceParticipantsProvider)
        : ref
                  .watch(voiceRosterProvider(channel.id))
                  .valueOrNull
                  ?.map(_asVoiceParticipant)
                  .toList(growable: false) ??
              const <VoiceParticipant>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppListRow(
          label: channel.name,
          selected: selected,
          unread: indicator.unread,
          mentioned: indicator.mentioned,
          muted: override == api.NotificationPreference.nothing,
          leading: ChannelKindIcon(
            isVoice: true,
            restricted: channel.restricted ?? false,
            color: iconColor,
          ),
          trailing: participants.isEmpty
              ? null
              : Text(
                  '${participants.length}',
                  style: AppText.micro.copyWith(
                    color: tokens.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
          trailingExtra: trailingExtra,
          onTap: () => openVoiceChannel(
            context,
            ProviderScope.containerOf(context, listen: false),
            channel.id,
            alreadySelected: selected,
          ),
        ),
        if (participants.isNotEmpty)
          RailParticipantList(
            participants: participants,
            channelId: channel.id,
          ),
      ],
    );
  }
}

/// A roster snapshot carries no live speaking or mute signal, so those two
/// flags are false rather than guessed; `isSharingScreen`/`hasVideo` are
/// read straight off the roster entry (see
/// docs/decisions/0032-voice-participant-webhooks.md).
VoiceParticipant _asVoiceParticipant(api.VoiceRosterParticipant p) =>
    VoiceParticipant(
      identity: p.userId,
      name: p.displayName,
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: p.isSharingScreen,
      isCameraOn: p.hasVideo,
    );
