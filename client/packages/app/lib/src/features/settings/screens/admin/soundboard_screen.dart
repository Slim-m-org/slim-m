// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Soundboard administration: create, listen to, edit and remove the Space's
/// clips (`/soundboard`), laid out as the Emoji pane is. Writing needs
/// MANAGE_SERVER, the same bit custom emoji use; reading is open to every
/// member.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../api_failure.dart';
import '../../../../audio/sound_clip_player.dart';
import '../../../../format.dart';
import '../../../../routing/routes.dart';
import '../../../../widgets/app_drop_zone.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/run_guarded.dart';
import '../../../emoji/widgets/stored_emoji.dart';
import '../../../members/providers/user_profiles.dart';
import '../../../voice/providers/soundboard_actions.dart';
import '../../../voice/providers/soundboard_clips.dart';
import '../../widgets/settings_catalog_card.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_entity_row.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import 'soundboard_clip_sheet.dart';
import 'soundboard_create.dart';
import 'soundboard_intake.dart';

class SoundboardScreen extends StatelessWidget {
  const SoundboardScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Soundboard',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    actions: [
      SoundboardCreateButton(),
      SizedBox(width: AppSpacing.s8),
    ],
    child: SoundboardPane(),
  );
}

class SoundboardPane extends ConsumerWidget {
  const SoundboardPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clips = ref.watch(soundClipsProvider);
    final count = clips.valueOrNull?.length;
    final profiles = ref.watch(batchProfilesControllerProvider);
    final intakeError = ref.watch(soundClipIntakeErrorProvider);
    resolveAuthorProfiles(ref, [
      for (final clip in clips.valueOrNull ?? const <api.SoundClip>[])
        clip.uploaderId,
    ]);
    return AppDropZone(
      enabled:
          count != null &&
          count < maxSoundClips &&
          !ref.watch(soundClipCreatingProvider),
      label: 'Drop to create a clip',
      icon: AppIcons.music,
      onDrop: (files, _) => unawaited(
        createSoundClip(
          context,
          ref,
          dropped: () => readDroppedSoundClip(files),
        ),
      ),
      child: AppAsyncView<List<api.SoundClip>>(
        value: AppAsyncState(data: clips.valueOrNull, error: clips.error),
        center: false,
        errorMessage: 'Could not load the soundboard.',
        onRetry: () => ref.invalidate(soundClipsProvider),
        data: (context, list) => SettingsCatalogCard(
          title: 'Clips',
          count: '${list.length} of $maxSoundClips',
          above: [
            if (intakeError != null)
              SettingsCardBlock(
                children: [
                  AppErrorState(
                    message: intakeError,
                    onDismiss: () =>
                        ref.read(soundClipIntakeErrorProvider.notifier).state =
                            null,
                  ),
                ],
              ),
          ],
          // At most 48 clips, so the page scrolls them rather than a box inside it.
          bounded: false,
          itemCount: list.length,
          itemBuilder: (context, index) => _ClipRow(
            key: ValueKey(list[index].id),
            clip: list[index],
            uploader: profiles[list[index].uploaderId]?.displayName,
          ),
          empty: const SettingsEmptyState(
            icon: AppIcons.soundboard,
            title: 'No clips yet.',
            detail: 'Create one from an mp3 or wav file, up to 5 seconds.',
          ),
        ),
      ),
    );
  }
}

class _ClipRow extends ConsumerStatefulWidget {
  const _ClipRow({super.key, required this.clip, required this.uploader});

  final api.SoundClip clip;

  /// Who added it, once their profile has loaded; a starter clip has nobody.
  final String? uploader;

  @override
  ConsumerState<_ClipRow> createState() => _ClipRowState();
}

class _ClipRowState extends ConsumerState<_ClipRow>
    with GuardedActionState<_ClipRow> {
  bool _busy = false;

  /// Plays on this device only: the admin hears it before anyone in a call does.
  Future<void> _listen() async {
    final clip = widget.clip;
    try {
      final audio = await ref.read(soundClipAudioProvider(clip.id).future);
      if (!mounted) return;
      await ref
          .read(soundClipPlayerProvider)
          .play(audio.bytes, mimeType: audio.contentType, volume: 1);
    } on Object catch (error, stack) {
      if (!mounted) return;
      // A failed fetch must not stay cached, or the clip stays silent until the app restarts.
      ref.invalidate(soundClipAudioProvider(clip.id));
      setActionError(
        reportFailureSentence(
          api.LogTag.voice,
          'play ${clip.name}',
          error,
          stack,
        ),
      );
    }
  }

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
    final wide = MediaQuery.sizeOf(context).width >= kCompactWidth;
    final length = formatClipLength(clip.durationMs);
    final uploader = widget.uploader;
    return SettingsEntityRow(
      dense: true,
      // Where an emoji row has its image, so the list shows what the call picker will.
      leading: StoredEmoji(
        clip.emoji,
        placeholder: AppIcons.music,
        size: AppSizes.icon24,
      ),
      headline: clip.name,
      badge: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _factsMaxWidth),
        child: Text(
          wide && uploader != null ? '$length · added by $uploader' : length,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ),
      actions: [
        AppIconButton(
          icon: AppIcons.play,
          semanticLabel: 'Listen to ${clip.name}',
          tooltip: 'Listen',
          onPressed: () => unawaited(_listen()),
        ),
        AppIconButton(
          icon: AppIcons.edit,
          semanticLabel: 'Edit ${clip.name}',
          tooltip: 'Edit',
          onPressed: _busy
              ? null
              : () => unawaited(showSoundClipSheet(context, clip: clip)),
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

/// Room for the length and a long display name, which ellipsizes past it.
const double _factsMaxWidth = 240;
