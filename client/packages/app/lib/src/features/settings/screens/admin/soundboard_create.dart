// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Creating a soundboard clip: choose or drop a file, then name it and give it
/// an emoji in one sheet before anything is sent, as Create emoji does, so a
/// taken or unusable name is fixed in place and a refusal keeps the file.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../action_labels.dart';
import '../../../voice/providers/soundboard_clips.dart';
import 'soundboard_clip_sheet.dart';
import 'soundboard_intake.dart';

/// The most clips one Space holds, mirrored from the server.
const maxSoundClips = 48;

/// True while a clip is being made, so a drop behind the sheet opens no second one.
final soundClipCreatingProvider = StateProvider<bool>((ref) => false);

/// Why the last file could not be chosen or read, shown on the pane until dismissed.
final soundClipIntakeErrorProvider = StateProvider<String?>((ref) => null);

/// Opens the clip sheet on the file [dropped] reads, or on the picker's when it is null.
Future<void> createSoundClip(
  BuildContext context,
  WidgetRef ref, {
  Future<SoundClipPick?> Function()? dropped,
}) async {
  final creating = ref.read(soundClipCreatingProvider.notifier);
  if (creating.state) return;
  final intakeError = ref.read(soundClipIntakeErrorProvider.notifier);
  creating.state = true;
  intakeError.state = null;
  try {
    final SoundClipPick? chosen;
    try {
      final SoundClipPicker read = dropped ?? ref.read(soundClipPickerProvider);
      chosen = await read();
    } on Object catch (error, stack) {
      final what = dropped == null ? 'open the file picker' : 'read that file';
      api.reportFailure(api.LogTag.media, 'choose a clip file', error, stack);
      intakeError.state = 'Could not $what.';
      return;
    }
    if (chosen == null || !context.mounted) return;
    await showSoundClipSheet(context, pick: chosen);
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
