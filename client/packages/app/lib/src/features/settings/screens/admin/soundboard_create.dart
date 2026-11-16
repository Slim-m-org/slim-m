// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Creating a soundboard clip: choose or drop a file, name it, then upload.
///
/// The name is asked for before anything is sent, as Create emoji does, so a
/// taken or unusable name is fixed in place and a refusal keeps the file.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../action_labels.dart';
import '../../../../widgets/name_sheet.dart';
import '../../../voice/providers/soundboard_actions.dart';
import '../../../voice/providers/soundboard_clips.dart';
import 'soundboard_intake.dart';

/// The most clips one Space holds, mirrored from the server.
const maxSoundClips = 48;

/// True while a clip is being named, so a drop behind the sheet opens no second one.
final soundClipCreatingProvider = StateProvider<bool>((ref) => false);

/// Names [pick], or the file the picker returns when it is null, and uploads it.
Future<void> createSoundClip(
  BuildContext context,
  WidgetRef ref, {
  SoundClipPick? pick,
}) async {
  final creating = ref.read(soundClipCreatingProvider.notifier);
  if (creating.state) return;
  creating.state = true;
  try {
    final chosen = pick ?? await ref.read(soundClipPickerProvider)();
    if (chosen == null || !context.mounted) return;
    final clips =
        ref.read(soundClipsProvider).valueOrNull ?? const <api.SoundClip>[];
    await showNameSheet(
      context,
      title: ActionLabels.createClip,
      caption: chosen.fileName,
      fieldLabel: 'Clip name',
      initial: chosen.suggestedName,
      maxChars: soundClipMaxNameChars,
      requireChange: false,
      saveLabel: ActionLabels.createClip,
      savingLabel: 'Creating...',
      whatFailed: 'create the clip',
      blocked: soundClipFileProblem(chosen),
      problem: (name) => soundClipNameProblem(name, clips),
      onSave: (ref, name) async {
        await ref
            .read(soundboardActionsProvider)
            .upload(chosen.bytes, name: name);
        ref.invalidate(soundClipsProvider);
      },
    );
  } finally {
    creating.state = false;
  }
}

/// The pane's one create button, in its title bar on both layouts.
class SoundboardCreateButton extends ConsumerWidget {
  const SoundboardCreateButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(soundClipsProvider).valueOrNull?.length;
    return AppButton(
      label: ActionLabels.createClip,
      icon: AppIcons.add,
      disabled: count == null || count >= maxSoundClips,
      onPressed: () => unawaited(createSoundClip(context, ref)),
    );
  }
}
