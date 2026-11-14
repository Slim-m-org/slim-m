// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Soundboard administration: add, rename and remove the Space's clips
/// (`/soundboard`). Writing needs MANAGE_SERVER, the same bit custom emoji use;
/// reading is open to every member.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../routing/routes.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/run_guarded.dart';
import '../../../voice/providers/soundboard_actions.dart';
import '../../../voice/providers/soundboard_clips.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_entity_row.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import 'soundboard_intake.dart';
import 'soundboard_rename_sheet.dart';

/// The most clips one Space holds, mirrored from the server.
const maxSoundClips = 48;

class SoundboardScreen extends StatelessWidget {
  const SoundboardScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Soundboard',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: SoundboardPane(),
  );
}

class SoundboardPane extends ConsumerStatefulWidget {
  const SoundboardPane({super.key});

  @override
  ConsumerState<SoundboardPane> createState() => _SoundboardPaneState();
}

class _SoundboardPaneState extends ConsumerState<SoundboardPane>
    with GuardedActionState<SoundboardPane> {
  bool _busy = false;

  Future<void> _add() async {
    final pick = await ref.read(soundClipPickerProvider)();
    if (pick == null || !mounted) return;
    if (pick.bytes.length > soundClipMaxBytes) {
      setActionError('That file is over 512 KB. A clip is at most 512 KB.');
      return;
    }
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'add the clip',
      action: () => ref
          .read(soundboardActionsProvider)
          .upload(pick.bytes, name: pick.suggestedName),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(soundClipsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final clips = ref.watch(soundClipsProvider);
    return AppAsyncView<List<api.SoundClip>>(
      value: AppAsyncState(data: clips.valueOrNull, error: clips.error),
      center: false,
      errorMessage: 'Could not load the soundboard.',
      onRetry: () => ref.invalidate(soundClipsProvider),
      data: (context, list) => SettingsSectionCard(
        title: 'Clips (${list.length} of $maxSoundClips)',
        description:
            'Short mp3 or wav clips, up to 5 seconds, played in calls.',
        children: [
          SettingsCardBlock(
            children: [
              AppButton(
                label: _busy ? 'Adding...' : 'Add clip',
                icon: AppIcons.add,
                disabled: _busy || list.length >= maxSoundClips,
                onPressed: _add,
              ),
              if (actionError != null) ...[
                const SizedBox(height: AppSpacing.s8),
                AppErrorState(
                  message: actionError!,
                  onDismiss: clearActionError,
                ),
              ],
            ],
          ),
          if (list.isEmpty)
            const SettingsEmptyState(
              icon: AppIcons.music,
              title: 'No clips yet.',
              detail: 'Add one and members can play it in a call.',
            )
          else
            for (final clip in list)
              _ClipRow(key: ValueKey(clip.id), clip: clip),
        ],
      ),
    );
  }
}

class _ClipRow extends ConsumerStatefulWidget {
  const _ClipRow({super.key, required this.clip});

  final api.SoundClip clip;

  @override
  ConsumerState<_ClipRow> createState() => _ClipRowState();
}

class _ClipRowState extends ConsumerState<_ClipRow>
    with GuardedActionState<_ClipRow> {
  bool _busy = false;

  Future<void> _remove() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Remove ${widget.clip.name}?',
      message: 'Members can no longer play it. This cannot be undone.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'remove the clip',
      action: () => ref.read(soundboardActionsProvider).delete(widget.clip.id),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(soundClipsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsEntityRow(
      dense: true,
      leading: Icon(
        AppIcons.music,
        size: AppSizes.icon20,
        color: tokens.textSecondary,
      ),
      headline: clip.name,
      badge: Text(
        '${(clip.durationMs / 1000).toStringAsFixed(1)} s',
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
      actions: [
        AppIconButton(
          icon: AppIcons.edit,
          semanticLabel: 'Rename ${clip.name}',
          onPressed: _busy
              ? null
              : () => unawaited(showRenameSoundClipSheet(context, clip: clip)),
        ),
        AppIconButton(
          icon: AppIcons.delete,
          semanticLabel: 'Remove ${clip.name}',
          variant: AppIconButtonVariant.danger,
          onPressed: _busy ? null : _remove,
        ),
      ],
      error: actionError,
      onErrorDismiss: clearActionError,
    );
  }
}
