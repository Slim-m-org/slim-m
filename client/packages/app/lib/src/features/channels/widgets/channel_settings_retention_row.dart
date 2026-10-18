// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' message retention: this channel's own window over the
/// Space's (`/channels/{id}/retention`), for someone who manages the Space,
/// since keeping a channel forever is an exemption from the Space's policy.
/// A shorter window says how many messages go and asks first, like the
/// Space's own control in `admin/performance_screen.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/widgets/settings_select_row.dart';
import '../../settings/widgets/settings_save_feedback.dart';
import '../../settings/screens/admin/performance_screen.dart'
    show retentionConfirmMessage, retentionDeletesHistory;

/// The channel's own window and the Space's, refetched each time settings open.
final channelRetentionProvider = FutureProvider.autoDispose
    .family<api.ChannelRetention, String>(
      (ref, channelId) => ref.watch(apiProvider).channelRetention(channelId),
    );

/// Stands for "follow the Space" in the select row, which needs a value.
const int _followSpace = -1;
const _dayChoices = [30, 90, 365];

String _window(int days) => days <= 0 ? 'Keep forever' : '$days days';

class ChannelRetentionRow extends ConsumerStatefulWidget {
  const ChannelRetentionRow({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<ChannelRetentionRow> createState() =>
      _ChannelRetentionRowState();
}

class _ChannelRetentionRowState extends ConsumerState<ChannelRetentionRow>
    with GuardedActionState<ChannelRetentionRow> {
  bool _saving = false;

  Future<void> _choose(int choice, api.ChannelRetention current) async {
    final own = choice == _followSpace ? null : choice;
    final from = current.days ?? current.spaceDays;
    final to = own ?? current.spaceDays;
    final client = ref.read(apiProvider);
    if (retentionDeletesHistory(from: from, to: to)) {
      int? count;
      try {
        count = await client.previewChannelRetention(widget.channelId, to);
      } on api.ApiException catch (error, stack) {
        api.reportFailure(api.LogTag.data, 'choose', error, stack);
        count = null;
      }
      if (!mounted) return;
      final confirmed = await confirmDangerousAction(
        context,
        title: 'Delete messages older than $to days?',
        message: retentionConfirmMessage(to, count),
        confirmLabel: count == 0 ? 'Set to $to days' : 'Delete old messages',
      );
      if (!confirmed || !mounted) return;
    }
    setState(() => _saving = true);
    await guard(
      whatFailed: 'change this channel\'s retention',
      action: () async {
        await client.setChannelRetention(widget.channelId, own);
        ref.invalidate(channelRetentionProvider(widget.channelId));
      },
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final current = ref
        .watch(channelRetentionProvider(widget.channelId))
        .valueOrNull;
    if (current == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSelectRow<int>(
          label: 'Message retention',
          sheetTitle: 'Message retention',
          sheetFootnote: 'How long this channel and its threads keep messages.',
          value: current.days ?? _followSpace,
          choices: [
            SettingsChoice(
              value: _followSpace,
              label: 'Space default (${_window(current.spaceDays)})',
            ),
            const SettingsChoice(value: 0, label: 'Keep forever'),
            for (final days in _dayChoices)
              SettingsChoice(value: days, label: _window(days)),
          ],
          onChanged: (choice) => _saving ? null : _choose(choice, current),
        ),
        SettingsSaveFeedback(
          inCard: true,
          tick: successTick,
          error: actionError,
          onDismissError: clearActionError,
        ),
      ],
    );
  }
}
