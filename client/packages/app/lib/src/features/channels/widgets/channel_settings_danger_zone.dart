// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' danger zone: `DELETE /channels/{id}`, with the same
/// confirm-then-delete flow the old `manage_channel_sheet` carried before
/// `channel_settings_screen.dart` replaced it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../providers/providers.dart';
import '../../../routing/close_screen.dart';
import '../../../routing/routes.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../settings/widgets/settings_danger_card.dart';

class ChannelDangerZoneSection extends ConsumerStatefulWidget {
  const ChannelDangerZoneSection({
    super.key,
    required this.channel,
    required this.wasOpen,
  });

  final Channel channel;

  /// Whether this channel was the one open behind the row whose kebab
  /// reached this screen - captured at that point rather than here; see
  /// `ChannelSettingsRouteArgs`'s own doc for why.
  final bool wasOpen;

  @override
  ConsumerState<ChannelDangerZoneSection> createState() =>
      _ChannelDangerZoneSectionState();
}

class _ChannelDangerZoneSectionState
    extends ConsumerState<ChannelDangerZoneSection> {
  bool _deleting = false;
  String? _error;

  Future<void> _confirmDelete() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Delete "${widget.channel.name}"?',
      message:
          'This deletes the channel and its message history for everyone '
          'in the Space. This cannot be undone.',
      confirmLabel: 'Delete permanently',
      cancelLabel: 'Keep channel',
    );
    if (confirmed) await _delete();
  }

  Future<void> _delete() async {
    setState(() {
      _deleting = true;
      _error = null;
    });
    final router = GoRouter.of(context);
    try {
      await ref.read(apiProvider).deleteChannel(widget.channel.id);
      final store = await ref.read(storeProvider.future);
      await store.removeChannel(widget.channel.id);
      if (!mounted) return;
      closeScreen(context, Routes.channels);
      // The view behind this screen may still show a channel that no longer exists.
      if (widget.wasOpen) router.go(Routes.channels);
    } on api.ConflictException {
      // The server's wording is accurate but terse; this feature wants a full sentence.
      if (mounted) {
        setState(
          () => _error =
              'This is the last channel here. Create another channel '
              'before deleting this one.',
        );
      }
    } on api.ApiException catch (e) {
      if (mounted) {
        setState(() => _error = describeApiFailure('delete the channel', e));
      }
    } finally {
      // Any escape, not just the two catches, must not wedge "Deleting..." on.
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsDangerCard(
    title: 'Danger zone',
    message: 'Deletes the channel and its message history for everyone.',
    action: AppButton(
      label: _deleting ? 'Deleting...' : 'Delete channel...',
      variant: AppButtonVariant.danger,
      size: AppButtonSize.sm,
      disabled: _deleting,
      onPressed: _confirmDelete,
    ),
    error: _error == null
        ? null
        : AppErrorState(
            message: _error!,
            onDismiss: () => setState(() => _error = null),
          ),
  );
}
