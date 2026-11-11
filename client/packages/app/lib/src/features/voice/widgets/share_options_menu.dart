// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the call dock's share menu offers, in the same four parts as the
/// microphone and camera menus: the source you are sharing, resolution and
/// frame rate, switches, and Stop sharing last.
///
/// Resolution and frame rate set the next share and, on a live one, restart it
/// where that needs no prompt; each is written through the notifier Voice
/// settings edits, so the two cannot disagree.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import '../providers/live_quality_restart.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_settings_controller.dart';
import '../providers/voice_state.dart' show ShareAudio;
import 'screen_source_sheet.dart' show screenSourceLabel;
import 'share_resolution_support.dart';

/// What a pick in the share menu does.
class ShareMenuActions {
  const ShareMenuActions({
    required this.onStop,
    required this.onChangeSource,
    required this.onPickSource,
  });

  final VoidCallback onStop;

  /// Opens the platform's own picker, where this app has no list of its own.
  final VoidCallback onChangeSource;
  final ValueChanged<ScreenShareSource> onPickSource;
}

/// The menu's entries for the current call state.
List<ControlOptionEntry> shareMenuEntries(
  WidgetRef ref, {
  required VoiceFlags voice,
  required VoiceController controller,
  required ShareMenuActions actions,
  ScreenShareSource? current,
}) {
  final sharing =
      voice.screenSharing && controller.video.screenShareNeedsSource;
  final settings = ref.watch(voiceSettingsControllerProvider);
  final notifier = ref.read(voiceSettingsControllerProvider.notifier);
  return joinMenuGroups([
    [if (sharing) _sharingRow(controller, actions, current)],
    _qualityChoices(ref, settings, notifier),
    [
      if (voice.shareAudio != ShareAudio.none)
        ControlSwitch(
          label: 'Share audio',
          value: voice.shareAudio == ShareAudio.on,
          onChanged: (on) =>
              unawaited(controller.share.setScreenShareAudioOn(on)),
        ),
      ControlSwitch(
        label: 'Viewers can draw',
        value: settings.screenShareAllowAnnotations,
        onChanged: (value) =>
            unawaited(notifier.setScreenShareAllowAnnotations(value)),
      ),
      if (controller.video.screenShareNeedsSource)
        ControlSwitch(
          label: 'Show my cursor',
          value: settings.screenShareShowCursor,
          onChanged: (value) =>
              unawaited(notifier.setScreenShareShowCursor(value)),
        ),
    ],
    [
      if (sharing)
        ControlOption(
          label: 'Stop sharing',
          icon: AppIcons.screenShareStop,
          tone: AppMenuItemTone.danger,
          onSelected: actions.onStop,
        ),
    ],
  ]);
}

ControlOptionEntry _sharingRow(
  VoiceController controller,
  ShareMenuActions actions,
  ScreenShareSource? current,
) {
  final value = current == null ? 'Screen' : screenSourceLabel(current);
  if (!controller.video.screenShareSourcePickerUseful) {
    return ControlOption(
      label: 'Sharing',
      value: value,
      icon: AppIcons.screenShare,
      onSelected: actions.onChangeSource,
    );
  }
  return ControlSubmenu(
    label: 'Sharing',
    icon: AppIcons.screenShare,
    value: value,
    panel: (context, close) => _SourceList(
      controller: controller,
      selectedId: current?.id,
      onPick: (source) {
        close();
        actions.onPickSource(source);
      },
    ),
  );
}

List<ControlOptionEntry> _qualityChoices(
  WidgetRef ref,
  VoiceSettingsState settings,
  VoiceSettingsController notifier,
) {
  final chosen = settings.screenShareQuality.resolution;
  final maxHeight = currentMaxShareHeight(ref, chosen);
  final shown = effectiveShareResolution(chosen, maxHeight);
  const resolutions = ScreenShareResolution.values;
  const rates = ScreenShareFps.values;
  return [
    ControlSegmented(
      label: 'Resolution',
      options: [
        for (final r in resolutions)
          AppSegmentedOption(
            label: r.label,
            disabled: !shareResolutionSupported(r, maxHeight),
            disabledReason: shareResolutionTooHighReason,
          ),
      ],
      selectedIndex: resolutions.indexOf(shown),
      onSelected: (i) =>
          unawaited(notifier.setScreenShareResolution(resolutions[i])),
    ),
    ControlSegmented(
      label: 'Frame rate',
      options: [for (final f in rates) AppSegmentedOption(label: f.label)],
      selectedIndex: rates.indexOf(settings.screenShareQuality.frameRate),
      onSelected: (i) => unawaited(notifier.setScreenShareFps(rates[i])),
    ),
    if (ref.watch(shareSettingsPendingProvider))
      ControlInline((context) => const _PendingNote()),
  ];
}

class _PendingNote extends StatelessWidget {
  const _PendingNote();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Text(
      shareSettingsPendingNote,
      style: AppText.caption.copyWith(color: tokens.textSecondary),
    );
  }
}

/// The screens and windows this desktop can share, listed once when the submenu opens.
class _SourceList extends StatefulWidget {
  const _SourceList({
    required this.controller,
    required this.selectedId,
    required this.onPick,
  });

  final VoiceController controller;
  final String? selectedId;
  final ValueChanged<ScreenShareSource> onPick;

  @override
  State<_SourceList> createState() => _SourceListState();
}

class _SourceListState extends State<_SourceList> {
  late final Future<List<ScreenShareSource>> _sources = widget.controller.video
      .screenShareSources();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ScreenShareSource>>(
      future: _sources,
      builder: (context, snapshot) {
        final sources = snapshot.data ?? const <ScreenShareSource>[];
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final source in sources)
              AppMenuItem(
                label: screenSourceLabel(source),
                leading: source.isWindow
                    ? AppIcons.windowRestore
                    : AppIcons.screenShare,
                selected: source.id == widget.selectedId,
                onTap: () => widget.onPick(source),
              ),
          ],
        );
      },
    );
  }
}
