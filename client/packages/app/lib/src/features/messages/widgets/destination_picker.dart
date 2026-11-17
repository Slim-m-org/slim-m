// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The destination picker a forward and a share both use: a search field over
/// every channel, DM, group and Notes the caller may post to, in the command
/// palette's sections and rows, driven by arrows and Enter on a pointer.
///
/// Only the picking lives here; what a pick does belongs to each caller.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/picker_key_hints.dart';
import '../../channels/widgets/channel_kind_icon.dart';
import '../../channels/widgets/group_avatar_stack.dart';
import '../../members/widgets/user_avatar.dart';
import '../../palette/widgets/command_palette_rows.dart'
    show PaletteRowShell, PaletteSectionHeader;
import '../../palette/widgets/palette_highlight.dart';
import '../../palette/widgets/palette_reveal.dart';
import '../providers/destination_sections.dart';
import '../providers/forward_targets.dart';

class DestinationPicker extends ConsumerStatefulWidget {
  const DestinationPicker({
    super.key,
    required this.query,
    required this.onPick,
    required this.enterLabel,
    required this.searchSemanticLabel,
    required this.errorMessage,
    required this.emptyMessage,
    this.currentChannelId,
    this.busyChannelId,
    this.searchKey,
  });

  final ForwardTargetsQuery query;
  final ValueChanged<ForwardTarget> onPick;

  /// What the key hints say Enter does.
  final String enterLabel;
  final String searchSemanticLabel;
  final String errorMessage;
  final String emptyMessage;

  /// Leads "Suggested" and carries the palette's current-channel bar.
  final String? currentChannelId;

  /// While set, that row spins and every row ignores picks.
  final String? busyChannelId;
  final Key? searchKey;

  static Key rowKey(String channelId) => Key('destination-row-$channelId');

  @override
  ConsumerState<DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends ConsumerState<DestinationPicker> {
  final _search = TextEditingController();
  int _highlighted = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<DestinationSection> _sections(List<ForwardTarget> all) =>
      destinationSections(
        all,
        search: _search.text,
        currentChannelId: widget.currentChannelId,
      );

  /// Read fresh rather than from the last build, so Enter straight after
  /// typing picks from what was typed.
  List<ForwardTarget> _flat() {
    final all = ref.read(forwardTargetsProvider(widget.query)).valueOrNull;
    return [for (final s in _sections(all ?? const [])) ...s.targets];
  }

  void _move(int delta) {
    final count = _flat().length;
    if (count == 0) return;
    setState(() => _highlighted = (_highlighted + delta) % count);
  }

  void _pick(ForwardTarget target) {
    if (widget.busyChannelId == null) widget.onPick(target);
  }

  void _pickHighlighted() {
    final flat = _flat();
    if (flat.isNotEmpty) _pick(flat[_highlighted.clamp(0, flat.length - 1)]);
  }

  @override
  Widget build(BuildContext context) {
    final touch = MediaQuery.sizeOf(context).width < kCompactWidth;
    final targets = ref.watch(forwardTargetsProvider(widget.query));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
            child: AppInput(
              key: widget.searchKey,
              controller: _search,
              autofocus: !touch,
              placeholder: 'Search channels and people',
              icon: const Icon(AppIcons.search),
              semanticLabel: widget.searchSemanticLabel,
              onChanged: (_) => setState(() => _highlighted = 0),
              onSubmitted: (_) => _pickHighlighted(),
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          Flexible(
            child: AppAsyncView(
              value: AppAsyncState(
                data: targets.valueOrNull,
                error: targets.error,
              ),
              errorMessage: widget.errorMessage,
              onRetry: () =>
                  ref.invalidate(forwardTargetsProvider(widget.query)),
              emptyMessage: widget.emptyMessage,
              isEmpty: (list) => list.isEmpty,
              data: (context, list) => _results(list, touch),
            ),
          ),
          if (!touch) PickerKeyHints(enterLabel: widget.enterLabel),
        ],
      ),
    );
  }

  Widget _results(List<ForwardTarget> all, bool touch) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final sections = _sections(all);
    final count = sections.fold(0, (n, s) => n + s.targets.length);
    if (count == 0) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: Text(
          'No matches.',
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
      );
    }
    _highlighted = _highlighted.clamp(0, count - 1);
    var at = 0;
    return ListView(
      key: const Key('destination-list'),
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
      children: [
        for (final section in sections)
          for (final (i, target) in section.targets.indexed)
            _row(target, at++, touch, header: i == 0 ? section.title : null),
      ],
    );
  }

  Widget _row(ForwardTarget target, int at, bool touch, {String? header}) {
    final highlighted = at == _highlighted && !touch;
    final current = target.channelId == widget.currentChannelId;
    return PaletteReveal(
      active: highlighted,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) PaletteSectionHeader(label: header),
          PaletteRowShell(
            key: DestinationPicker.rowKey(target.channelId),
            highlighted: highlighted,
            touch: touch,
            current: current,
            semanticLabel: target.label,
            onTap: () => _pick(target),
            child: _DestinationBody(
              target: target,
              search: _search.text.trim(),
              busy: widget.busyChannelId == target.channelId,
              dimmed: widget.busyChannelId != null,
              current: current,
            ),
          ),
        ],
      ),
    );
  }
}

class _DestinationBody extends StatelessWidget {
  const _DestinationBody({
    required this.target,
    required this.search,
    required this.busy,
    required this.dimmed,
    required this.current,
  });

  final ForwardTarget target;
  final String search;
  final bool busy;
  final bool dimmed;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final colour = dimmed && !busy ? tokens.textDisabled : tokens.textPrimary;
    return Row(
      spacing: AppSpacing.s12,
      children: [
        // Boxed to one width so every name starts on one line.
        SizedBox.square(
          dimension: AppAvatarSize.s28,
          child: Center(child: _leading(tokens)),
        ),
        Expanded(
          child: paletteHighlighted(
            target.label,
            search,
            AppText.ui.copyWith(color: colour),
          ),
        ),
        if (busy)
          const AppSpinner(size: AppSpinnerSize.sm)
        else if (current)
          Text(
            'This channel',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
      ],
    );
  }

  Widget _leading(AppTokens tokens) {
    if (target.groupMemberIds case final ids?) {
      return GroupAvatarStack(memberIds: ids, size: AppAvatarSize.s24);
    }
    if (target.isPersonalSpace) {
      return Icon(
        AppIcons.notebook,
        size: AppSizes.icon20,
        color: tokens.textSecondary,
      );
    }
    if (target.userId case final userId? when target.isDm) {
      return UserAvatar.known(
        userId: userId,
        avatarUpdatedAt: target.avatarUpdatedAt,
        name: target.label,
        size: AppAvatarSize.s28,
      );
    }
    if (target.isDm) {
      return Icon(
        AppIcons.account,
        size: AppSizes.icon20,
        color: tokens.textSecondary,
      );
    }
    return ChannelKindIcon(
      isVoice: target.isVoice,
      restricted: target.restricted,
      color: tokens.textSecondary,
      size: AppSizes.icon20,
    );
  }
}
