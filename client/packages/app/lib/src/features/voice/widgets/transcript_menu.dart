// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call's transcript controls in one menu: the captions switch, Mark and
/// "Add a note". Shown only while the call is transcribed for this member.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/call_mark_actions.dart';
import '../providers/live_call_transcript.dart';
import '../providers/voice_settings_controller.dart';
import 'call_note_sheet.dart';
import 'dock_menu_button.dart';

const markButtonKey = Key('call-mark-button');

/// Whether [channelId]'s call offers captions to this member: the server
/// transcribes it and they may read the transcript.
bool canUseCaptions(WidgetRef ref, String? channelId) =>
    channelId != null &&
    ref.watch(liveCallTranscriptIdProvider(channelId)) != null;

/// The menu rows: [context] must outlive the menu, since the note sheet opens from it.
List<Widget> transcriptMenuItems(
  BuildContext context,
  WidgetRef ref,
  VoidCallback close,
) => [
  const _CaptionsSwitchRow(),
  AppMenuItem(
    key: markButtonKey,
    label: 'Mark this moment',
    leading: AppIcons.callMark,
    onTap: () {
      close();
      unawaited(ref.read(callMarkActionsProvider).mark());
    },
  ),
  AppMenuItem(
    label: 'Add a note',
    leading: AppIcons.callNote,
    onTap: () {
      close();
      unawaited(showCallNoteSheet(context));
    },
  ),
];

class _CaptionsSwitchRow extends ConsumerWidget {
  const _CaptionsSwitchRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.showCaptions),
    );
    return AppMenuSwitchRow(
      label: 'Captions',
      value: on,
      onChanged: (next) => unawaited(
        ref
            .read(voiceSettingsControllerProvider.notifier)
            .setShowCaptions(next),
      ),
    );
  }
}

/// The dock's Transcript button, lit while captions are on.
class TranscriptDockButton extends ConsumerWidget {
  const TranscriptDockButton({super.key, required this.menuContext});

  final BuildContext menuContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.showCaptions),
    );
    return DockMenuButton(
      icon: AppIcons.callCaptions,
      tooltip: 'Transcript',
      active: on,
      sheetLabel: 'Transcript',
      menuWidth: 240,
      itemsBuilder: (_, close) => transcriptMenuItems(menuContext, ref, close),
    );
  }
}
