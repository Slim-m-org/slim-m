// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' "Discard hidden canvas" row for a voice channel whose canvas is off: it asks first, then removes everything on the hidden board.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unaliased for the `ChannelUpdate` type; `Channel` hidden to avoid `slimm_data`'s.
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/toasts.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/widgets/settings_detail_row.dart' show SettingsActionRow;
import '../providers/channel_actions.dart';
import '../providers/channel_by_id_provider.dart';

class ChannelDiscardCanvasSection extends ConsumerStatefulWidget {
  const ChannelDiscardCanvasSection({super.key, required this.channel});

  final Channel channel;

  @override
  ConsumerState<ChannelDiscardCanvasSection> createState() =>
      _ChannelDiscardCanvasSectionState();
}

class _ChannelDiscardCanvasSectionState
    extends ConsumerState<ChannelDiscardCanvasSection> {
  bool _busy = false;
  String? _error;

  Future<void> _discard() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Discard the hidden canvas?',
      message: 'Everything on it is removed, locked items too.',
      confirmLabel: 'Discard',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final actions = ref.read(channelActionsProvider);
    final toasts = ref.read(toastsProvider.notifier);
    final failure = await runGuarded(
      whatFailed: 'discard the hidden canvas',
      action: () async {
        await actions.update(
          widget.channel.id,
          const ChannelUpdate(discardCanvas: true),
        );
      },
    );
    if (failure == null) toasts.show('Hidden canvas discarded.');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final stored =
        ref.watch(channelByIdProvider(widget.channel.id)).valueOrNull ??
        widget.channel;
    if (stored.hasCanvas) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsActionRow(
          message: "Removes everything on this channel's hidden board.",
          action: AppButton(
            label: _busy ? 'Discarding...' : 'Discard canvas...',
            variant: AppButtonVariant.danger,
            size: AppButtonSize.sm,
            disabled: _busy,
            onPressed: _discard,
          ),
        ),
        if (_error case final message?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s16,
            ),
            child: AppErrorState(
              message: message,
              onDismiss: () => setState(() => _error = null),
            ),
          ),
      ],
    );
  }
}
