// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one sheet a clip is made or changed in: the file with a Listen button
/// while creating, then its name and its emoji, as Create emoji stages an
/// image beside its name.
///
/// `showAppSheet`: a bottom sheet on a phone, a centred dialog on a desktop
/// (`docs/design/desktop-vs-mobile.md`, rule 4).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../action_labels.dart';
import '../../../../api_failure.dart';
import '../../../../audio/sound_clip_player.dart';
import '../../../../format.dart';
import '../../../../widgets/app_drop_zone.dart';
import '../../../../widgets/run_guarded.dart';
import '../../../voice/providers/soundboard_actions.dart';
import '../../../voice/providers/soundboard_clips.dart';
import '../../widgets/settings_field.dart';
import '../../widgets/settings_file_thumb.dart';
import 'soundboard_emoji_field.dart';
import 'soundboard_intake.dart';

/// Opens the sheet: from [pick] it creates a clip, for [clip] it edits that
/// clip's name and emoji. True once saved.
Future<bool> showSoundClipSheet(
  BuildContext context, {
  SoundClipPick? pick,
  api.SoundClip? clip,
}) async {
  assert((pick == null) != (clip == null), 'a file to create, or a clip');
  final title = clip == null ? ActionLabels.createClip : 'Edit ${clip.name}';
  final saved = await showAppSheet<bool>(
    context,
    semanticLabel: title,
    builder: (_) => _ClipSheet(title: title, pick: pick, clip: clip),
  );
  return saved ?? false;
}

class _ClipSheet extends ConsumerStatefulWidget {
  const _ClipSheet({required this.title, this.pick, this.clip});

  final String title;
  final SoundClipPick? pick;
  final api.SoundClip? clip;

  @override
  ConsumerState<_ClipSheet> createState() => _ClipSheetState();
}

class _ClipSheetState extends ConsumerState<_ClipSheet>
    with GuardedActionState<_ClipSheet> {
  late SoundClipPick? _pick = widget.pick;
  late final _name = TextEditingController(
    text: widget.clip?.name ?? widget.pick!.suggestedName,
  );
  late String? _emoji = widget.clip?.emoji;
  bool _busy = false;

  bool get _creating => widget.clip == null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _trimmed => _name.text.trim();

  List<api.SoundClip> get _clips =>
      ref.read(soundClipsProvider).valueOrNull ?? const [];

  String? get _problem => _trimmed.isEmpty
      ? null
      : soundClipNameProblem(_trimmed, _clips, renaming: widget.clip?.id);

  String? get _fileProblem {
    final pick = _pick;
    return pick == null ? null : soundClipFileProblem(pick);
  }

  bool get _changed {
    final clip = widget.clip;
    return clip == null || _trimmed != clip.name || _emoji != clip.emoji;
  }

  bool get _canSave =>
      !_busy &&
      _fileProblem == null &&
      _trimmed.isNotEmpty &&
      inputCharCount(_trimmed) <= soundClipMaxNameChars &&
      _problem == null &&
      _changed;

  void _use(SoundClipPick pick) {
    clearActionError();
    final keepName = _trimmed != _pick?.suggestedName;
    setState(() {
      _pick = pick;
      if (!keepName) _name.text = pick.suggestedName;
    });
  }

  Future<void> _replace() async {
    final SoundClipPick? pick;
    try {
      pick = await ref.read(soundClipPickerProvider)();
    } on Object catch (error, stack) {
      api.reportFailure(api.LogTag.media, 'choose a clip file', error, stack);
      setActionError('Could not open the file picker.');
      return;
    }
    if (pick != null && mounted) _use(pick);
  }

  Future<void> _dropped(List<DropItem> files) async {
    final pick = await readDroppedSoundClip(files);
    if (pick != null && mounted) _use(pick);
  }

  /// Plays the chosen file on this device only, before anyone else hears it.
  Future<void> _listen() async {
    final pick = _pick!;
    try {
      await ref
          .read(soundClipPlayerProvider)
          .play(
            Uint8List.fromList(pick.bytes),
            mimeType: soundClipMimeType(pick.fileName),
            volume: 1,
          );
    } on Object catch (error, stack) {
      if (!mounted) return;
      setActionError(
        reportFailureSentence(
          api.LogTag.voice,
          'play ${pick.fileName}',
          error,
          stack,
        ),
      );
    }
  }

  Future<void> _save() async {
    final name = _trimmed;
    final emoji = _emoji;
    final actions = ref.read(soundboardActionsProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    final clip = widget.clip;
    final pick = _pick;
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: _creating ? 'create the clip' : 'save the clip',
      action: () async {
        if (clip == null) {
          await actions.upload(pick!.bytes, name: name, emoji: emoji);
        } else {
          await actions.edit(clip.id, name: name, emoji: emoji);
        }
        container.invalidate(soundClipsProvider);
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final pick = _pick;
    final fileProblem = _fileProblem;
    return AppDropZone(
      enabled: _creating && !_busy,
      label: 'Drop to use another file',
      icon: AppIcons.music,
      onDrop: (files) => unawaited(_dropped(files)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s16,
          0,
          AppSpacing.s16,
          AppSpacing.s16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AppSpacing.s12,
            children: [
              AppSheetHeader(
                widget.title,
                caption: _creating
                    ? 'An mp3 or wav file, up to 5 seconds and 512 KB.'
                    : null,
                padding: EdgeInsets.zero,
                trailing: AppIconButton(
                  icon: AppIcons.dismiss,
                  semanticLabel: 'Close',
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              if (pick != null)
                _FileRow(
                  pick: pick,
                  enabled: !_busy,
                  onListen: () => unawaited(_listen()),
                  onReplace: () => unawaited(_replace()),
                ),
              if (fileProblem != null) AppErrorState(message: fileProblem),
              SettingsField(
                label: 'Name',
                child: AppInput(
                  counterMax: soundClipMaxNameChars,
                  controller: _name,
                  autofocus: true,
                  enabled: !_busy,
                  errorText: _problem,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (_canSave) unawaited(_save());
                  },
                  semanticLabel: 'Clip name',
                ),
              ),
              SettingsField(
                label: 'Emoji',
                child: SoundClipEmojiField(
                  value: _emoji,
                  enabled: !_busy,
                  onChanged: (emoji) => setState(() => _emoji = emoji),
                ),
              ),
              if (actionError case final error?)
                AppErrorState(message: error, onDismiss: clearActionError),
              AppButton(
                label: _busy
                    ? (_creating ? 'Creating...' : 'Saving...')
                    : (_creating ? ActionLabels.createClip : 'Save'),
                variant: AppButtonVariant.primary,
                full: true,
                disabled: !_canSave,
                onPressed: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The chosen file: its name and size, a Listen button, and a way to swap it.
class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.pick,
    required this.enabled,
    required this.onListen,
    required this.onReplace,
  });

  final SoundClipPick pick;
  final bool enabled;
  final VoidCallback onListen;
  final VoidCallback onReplace;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      spacing: AppSpacing.s12,
      children: [
        SettingsFileThumb(
          child: Icon(
            AppIcons.music,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pick.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui.copyWith(color: tokens.textPrimary),
              ),
              Text(
                formatByteSize(pick.bytes.length),
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s4,
          children: [
            AppIconButton(
              icon: AppIcons.play,
              semanticLabel: 'Listen to ${pick.fileName}',
              tooltip: 'Listen',
              onPressed: enabled ? onListen : null,
            ),
            AppButton(
              label: 'Replace',
              size: AppButtonSize.sm,
              semanticLabel: 'Choose another file',
              disabled: !enabled,
              onPressed: onReplace,
            ),
          ],
        ),
      ],
    );
  }
}
