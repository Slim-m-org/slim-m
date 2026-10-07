// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Controls a bot puts in a call, shown in the call's dock only while that bot
/// is on the call. See docs/decisions/0045-bot-contributed-ui.md.
///
/// Every width gets the same shape (docs/design/desktop-vs-mobile.md, law 2:
/// tokens and type never scale with width): a bot is one row, its name as a
/// small label, then an icon chip per control, the same chip the call's own
/// controls use, labelled by tooltip and semantics. The chips grow to the
/// touch floor by themselves and wrap rather than scroll. A control that
/// offers options opens them as a menu, a sheet on a compact window, the same
/// way every other menu here does (rule 1).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/bot_ui_uses.dart';
import '../screens/call_dock_button.dart';
import 'context_menu_region.dart';

/// One bot's controls for the call.
class BotCallGroup {
  const BotCallGroup({required this.bot, required this.controls});

  final api.ChannelBotUi bot;
  final List<api.BotUiEntry> controls;
}

/// The bots that both registered controls and are on the call, so a bot that
/// has left leaves nothing behind. [participantIds] are the call's user ids.
List<BotCallGroup> botCallGroups(
  List<api.ChannelBotUi> bots,
  Set<String> participantIds,
) => [
  for (final bot in bots)
    if (bot.callControls.isNotEmpty && participantIds.contains(bot.botUserId))
      BotCallGroup(bot: bot, controls: bot.callControls),
];

/// A control used, with the option chosen when it offers a choice.
typedef _OnUse = void Function(api.BotUiEntry control, String? optionId);

/// Widest a bot's name grows beside its chips before it ellipsizes.
const double _compactNameMaxWidth = 88;

/// Widest the strip grows, so a wide window keeps it a control and not a bar.
const double _maxWidth = 480;

IconData _iconFor(String? name) => switch (name) {
  'play' => AppIcons.play,
  'pause' => AppIcons.pause,
  'stop' => AppIcons.callStop,
  'skip_next' => AppIcons.callSkipNext,
  'skip_previous' => AppIcons.callSkipPrevious,
  'volume' => AppIcons.speaker,
  'volume_off' => AppIcons.speakerOff,
  'repeat' => AppIcons.callRepeat,
  'shuffle' => AppIcons.callShuffle,
  'list' => AppIcons.callList,
  'settings' => AppIcons.settings,
  _ => AppIcons.callControl,
};

class BotCallControls extends ConsumerWidget {
  const BotCallControls({
    super.key,
    required this.channelId,
    required this.groups,
  });

  final String channelId;
  final List<BotCallGroup> groups;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (groups.isEmpty) return const SizedBox.shrink();
    final uses = ref.watch(botUiUsesProvider);
    final controller = ref.read(botUiUsesProvider.notifier);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in groups)
            _Group(
              group: group,
              uses: {
                for (final control in group.controls)
                  control.id:
                      uses[controlUseKey(
                        channelId,
                        group.bot.botUserId,
                        control.id,
                      )],
              },
              onUse: (control, optionId) => unawaited(
                controller.useCallControl(
                  channelId: channelId,
                  botId: group.bot.botUserId,
                  entryId: control.id,
                  optionId: optionId,
                ),
              ),
              onDismiss: (control) => controller.dismiss(
                controlUseKey(channelId, group.bot.botUserId, control.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({
    required this.group,
    required this.uses,
    required this.onUse,
    required this.onDismiss,
  });

  final BotCallGroup group;
  final Map<String, BotUiUse?> uses;
  final _OnUse onUse;
  final ValueChanged<api.BotUiEntry> onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final failed = group.controls
        .where((c) => uses[c.id]?.failure != null)
        .firstOrNull;
    final name = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            group.bot.botDisplayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
        const SizedBox(width: AppSpacing.s8),
        const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot'),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CompactRow(
            name: name,
            controls: group.controls,
            uses: uses,
            onUse: onUse,
          ),
          if (failed != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: AppErrorState(
                message: uses[failed.id]!.failure!,
                onRetry: () {
                  onDismiss(failed);
                  unawaited(uses[failed.id]!.retry());
                },
                onDismiss: () => onDismiss(failed),
              ),
            ),
        ],
      ),
    );
  }
}

class _CompactRow extends StatelessWidget {
  const _CompactRow({
    required this.name,
    required this.controls,
    required this.uses,
    required this.onUse,
  });

  final Widget name;
  final List<api.BotUiEntry> controls;
  final Map<String, BotUiUse?> uses;
  final _OnUse onUse;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _compactNameMaxWidth),
        child: name,
      ),
      const SizedBox(width: AppSpacing.s8),
      Expanded(
        child: Wrap(
          alignment: WrapAlignment.end,
          runAlignment: WrapAlignment.end,
          children: [
            for (final control in controls)
              _ControlChip(
                control: control,
                pending: uses[control.id]?.pending ?? false,
                onUse: onUse,
              ),
          ],
        ),
      ),
    ],
  );
}

/// One control's chip. A plain control is used on press; one that offers
/// options opens them, and the pick is the use.
class _ControlChip extends StatefulWidget {
  const _ControlChip({
    required this.control,
    required this.pending,
    required this.onUse,
  });

  final api.BotUiEntry control;
  final bool pending;
  final _OnUse onUse;

  @override
  State<_ControlChip> createState() => _ControlChipState();
}

class _ControlChipState extends State<_ControlChip> {
  final _menu = GlobalKey<ContextMenuRegionState>();

  @override
  Widget build(BuildContext context) {
    final control = widget.control;
    final chip = CallDockButton(
      icon: _iconFor(control.icon),
      tooltip: control.label,
      active: false,
      pending: widget.pending,
      onPressed: control.options.isEmpty
          ? () => widget.onUse(control, null)
          : () => _menu.currentState?.open(),
    );
    if (control.options.isEmpty) return chip;
    return ContextMenuRegion(
      key: _menu,
      // The chip is already a tab stop and owns its press.
      ownsFocusNode: false,
      enableLongPress: false,
      opensAbove: true,
      itemsBuilder: (context, close) => [
        AppMenuLabel(control.label),
        for (final option in control.options)
          AppMenuItem(
            label: option.label,
            onTap: () {
              close();
              widget.onUse(control, option.id);
            },
          ),
      ],
      child: chip,
    );
  }
}
