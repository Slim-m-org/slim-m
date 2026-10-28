// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Voice Settings' microphone and speaker pickers.
///
/// Each row lists real devices through `VoiceController.audioInputDevices`/
/// `audioOutputDevices` and refreshes on `VoiceController.audioDeviceChanges`
/// - a headset plugged in or removed - rather than only once on open.
///
/// A platform that cannot honour a live switch (mobile for the microphone,
/// web and iOS for the speaker; see `AudioDeviceSwitching`'s own doc
/// comments for why) gets a caption instead of a picker that would quietly
/// do nothing, matching this repo's rule against a dead control.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../audio/sound_output_router.dart';
import '../../settings/providers/notification_sound_controller.dart';
import '../providers/mic_preview.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import '../../settings/widgets/settings_hairline.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../../settings/widgets/settings_select_row.dart';
import '../../settings/widgets/settings_toggle_row.dart';

/// [SettingsSelectRow] reserves null for "no choice known yet"; this sentinel
/// stands in for the system default so a real, known choice can still be
/// represented as a non-null [String] value.
const _systemDefaultId = '';

const speakerTestRowKey = ValueKey('speaker-test-row');

class AudioDeviceSection extends ConsumerStatefulWidget {
  const AudioDeviceSection({super.key, this.embedded = false});

  /// Rows only, for a card another section already owns.
  final bool embedded;

  @override
  ConsumerState<AudioDeviceSection> createState() => _AudioDeviceSectionState();
}

class _AudioDeviceSectionState extends ConsumerState<AudioDeviceSection> {
  List<AudioDevice> _inputs = const [];
  List<AudioDevice> _outputs = const [];
  // The empty lists before the first answer must not read as "unplugged".
  bool _listed = false;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _changes = ref
        .read(voiceControllerProvider.notifier)
        .audioDeviceChanges
        .listen((_) => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    final notifier = ref.read(voiceControllerProvider.notifier);
    final inputs = await notifier.audioInputDevices();
    final outputs = await notifier.audioOutputDevices();
    if (!mounted) return;
    setState(() {
      _inputs = inputs;
      _outputs = outputs;
      _listed = true;
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Opening the capture is what makes some hosts list their devices at all.
    ref.listen(micPreviewProvider.select((r) => r.status), (before, now) {
      if (now == MicPreviewStatus.live && before != now) unawaited(_refresh());
    });
    final settings = ref.watch(voiceSettingsControllerProvider);
    final notifier = ref.read(voiceControllerProvider.notifier);
    final settingsNotifier = ref.read(voiceSettingsControllerProvider.notifier);

    final rows = [
      _DevicePickerRow(
        label: 'Microphone',
        icon: AppIcons.mic,
        supported: notifier.supportsAudioInputSelection,
        unsupportedCaption: 'This platform routes microphones automatically.',
        devices: _inputs,
        listed: _listed,
        selectedId: settings.audioInputDeviceId,
        onChanged: settingsNotifier.setAudioInputDevice,
      ),
      if (notifier.supportsAudioInputSelection)
        SettingsToggleRow(
          label: 'Switch if mic stops working',
          description: 'Use another microphone when yours goes silent.',
          value: settings.micFallbackEnabled,
          semanticLabel: 'Switch microphone if mine stops working',
          onChanged: settingsNotifier.setMicFallbackEnabled,
        ),
      _DevicePickerRow(
        label: 'Speaker',
        icon: AppIcons.speaker,
        supported: notifier.supportsAudioOutputSelection,
        unsupportedCaption:
            'This platform always plays a call through its default output.',
        devices: _outputs,
        listed: _listed,
        selectedId: settings.audioOutputDeviceId,
        onChanged: settingsNotifier.setAudioOutputDevice,
      ),
      const SpeakerTestRow(),
    ];
    if (widget.embedded) return SettingsRowGroup(children: rows);
    return SettingsSectionCard(
      title: 'Input and output devices',
      description: 'Which microphone and speaker a call uses.',
      children: rows,
    );
  }
}

class SpeakerTestRow extends ConsumerWidget {
  const SpeakerTestRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuilt when the pick changes: whether the chime follows it depends on it.
    ref.watch(
      voiceSettingsControllerProvider.select((s) => s.audioOutputDeviceId),
    );
    final testable = ref.read(soundOutputRouterProvider).testable;
    return AppListRow(
      key: speakerTestRowKey,
      label: 'Test speaker',
      subtitle: testable
          ? null
          : 'Interface sounds play on the system default output.',
      trailing: testable
          ? AppButton(
              size: AppButtonSize.sm,
              label: 'Play',
              onPressed: () => unawaited(
                ref.read(notificationSoundControllerProvider).playSpeakerTest(),
              ),
            )
          : null,
    );
  }
}

class _DevicePickerRow extends StatelessWidget {
  const _DevicePickerRow({
    required this.label,
    required this.icon,
    required this.supported,
    required this.unsupportedCaption,
    required this.devices,
    required this.listed,
    required this.selectedId,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final bool supported;
  final String unsupportedCaption;
  final List<AudioDevice> devices;
  final bool listed;
  final String? selectedId;
  final ValueChanged<AudioDevice?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!supported) {
      return AppListRow(
        label: label,
        subtitle: unsupportedCaption,
        meta: 'Default',
      );
    }

    final tokens = Theme.of(context).extension<AppTokens>()!;
    final resolved = resolveAudioDevice(devices, selectedId);
    final unplugged = listed && selectedId != null && resolved == null;
    final kind = label == 'Microphone' ? 'mic' : 'speaker';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSelectRow<String>(
          label: label,
          sheetTitle: label,
          value: resolved?.id ?? _systemDefaultId,
          choices: [
            const SettingsChoice(
              value: _systemDefaultId,
              label: 'System default',
            ),
            for (final device in devices)
              SettingsChoice(
                value: device.id,
                label: device.label.isEmpty ? 'Unnamed device' : device.label,
              ),
          ],
          onChanged: (id) {
            if (id == _systemDefaultId) return onChanged(null);
            // The list can change between opening the sheet and picking.
            final device = devices.where((d) => d.id == id).firstOrNull;
            if (device != null) onChanged(device);
          },
        ),
        if (unplugged)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s12,
            ),
            child: Row(
              spacing: AppSpacing.s8,
              children: [
                Icon(
                  AppIcons.warning,
                  size: AppSizes.icon16,
                  color: tokens.warnText,
                ),
                Expanded(
                  child: Text(
                    "Your chosen $kind isn't connected. Using the system "
                    'default.',
                    style: AppText.caption.copyWith(color: tokens.warnText),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
