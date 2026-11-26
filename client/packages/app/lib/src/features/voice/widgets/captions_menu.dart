// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call's one Captions control (decision 0113): the captions switch, and
/// while the transcript runs, "View transcript", Mark and "Add a note".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart' show AppAction;

import '../../../widgets/shortcut_label.dart';
import '../providers/call_audio.dart';
import '../providers/call_captions.dart';
import '../providers/call_mark_actions.dart';
import '../providers/voice_text_tab.dart';
import 'call_audio_start.dart';
import 'call_note_sheet.dart';
import 'dock_menu_button.dart';

const markButtonKey = Key('call-mark-button');
const captionsSwitchKey = Key('call-captions-switch');
const captionsPendingKey = Key('call-captions-pending');
const viewTranscriptKey = Key('call-view-transcript');

/// The menu rows: [context] must outlive the menu, since the sheets open from it.
List<Widget> captionsMenuItems(
  BuildContext context,
  WidgetRef ref,
  VoidCallback close,
  String channelId,
) => [
  Consumer(
    builder: (_, inner, _) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: switch (inner.watch(captionsControlProvider(channelId))) {
        CaptionsControl.hidden => const [],
        CaptionsControl.pending => [_PendingRow(channelId: channelId)],
        CaptionsControl.startable => [
          _switchRow(
            inner.watch(captionsOnProvider(channelId)),
            (_) => unawaited(_ask(context, ref, close, channelId)),
          ),
        ],
        CaptionsControl.running => [
          _switchRow(
            inner.watch(captionsOnProvider(channelId)),
            (on) => ref
                .read(callCaptionsProvider(channelId).notifier)
                .setCaptions(on),
          ),
          AppMenuItem(
            key: viewTranscriptKey,
            label: 'View transcript',
            leading: AppIcons.callTranscript,
            onTap: () {
              close();
              _viewTranscript(ref, channelId);
            },
          ),
          AppMenuItem(
            key: markButtonKey,
            label: labelWithShortcut(
              'Mark this moment',
              AppAction.markCallMoment,
            ),
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
        ],
      },
    ),
  ),
];

Widget _switchRow(bool on, ValueChanged<bool> onChanged) => AppMenuSwitchRow(
  key: captionsSwitchKey,
  label: 'Captions',
  value: on,
  onChanged: onChanged,
);

/// Asks everyone, as the Transcribe control did, and turns captions on once it is asked.
Future<void> _ask(
  BuildContext context,
  WidgetRef ref,
  VoidCallback close,
  String channelId,
) async {
  close();
  if (!await confirmTranscribeCall(context)) return;
  final captions = ref.read(callCaptionsProvider(channelId).notifier)
    ..setCaptions(true);
  final audio = ref.read(callAudioProvider(channelId).notifier);
  await audio.requestTranscript();
  if (ref.read(callAudioProvider(channelId)).error != null) captions.reset();
}

void _viewTranscript(WidgetRef ref, String channelId) {
  ref.read(callCaptionsProvider(channelId).notifier).showTranscript();
  ref.read(voiceTextTabProvider.notifier).state = VoiceTextTab.transcript;
  ref.read(voiceChatPaneVisibleProvider.notifier).state = true;
}

class _PendingRow extends ConsumerWidget {
  const _PendingRow({required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(
      callAudioProvider(channelId).select((m) => m.session),
    );
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppMenuItem(
      key: captionsPendingKey,
      label: 'Waiting for everyone',
      leading: AppIcons.callCaptions,
      trailing: session == null
          ? null
          : Text(
              '${session.answered} of ${session.total}',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
    );
  }
}

/// The dock's Captions button, lit while captions are on or being asked for.
class CaptionsDockButton extends ConsumerWidget {
  const CaptionsDockButton({
    super.key,
    required this.menuContext,
    required this.channelId,
  });

  final BuildContext menuContext;
  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(captionsOnProvider(channelId));
    final pending =
        ref.watch(captionsControlProvider(channelId)) ==
        CaptionsControl.pending;
    return DockMenuButton(
      icon: AppIcons.callCaptions,
      tooltip: pending ? 'Captions, waiting for everyone' : 'Captions',
      active: on,
      sheetLabel: 'Captions',
      menuWidth: 260,
      itemsBuilder: (_, close) =>
          captionsMenuItems(menuContext, ref, close, channelId),
    );
  }
}
