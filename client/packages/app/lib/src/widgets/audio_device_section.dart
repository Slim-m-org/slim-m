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

import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';

/// [SettingsSelectRow] reserves null for "no choice known yet"; this sentinel
/// stands in for the system default so a real, known choice can still be
/// represented as a non-null [String] value.
const _systemDefaultId = '';

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
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        selectedId: settings.audioInputDeviceId,
        onChanged: settingsNotifier.setAudioInputDevice,
      ),
      const SizedBox(height: AppSpacing.s8),
      _DevicePickerRow(
        label: 'Speaker',
        icon: AppIcons.speaker,
        supported: notifier.supportsAudioOutputSelection,
        unsupportedCaption:
            'This platform always plays a call through its default output.',
        devices: _outputs,
        selectedId: settings.audioOutputDeviceId,
        onChanged: settingsNotifier.setAudioOutputDevice,
      ),
    ];
    if (widget.embedded) return Column(children: rows);
    return SettingsSectionCard(
      title: 'Input and output devices',
      description: 'Which microphone and speaker a call uses.',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
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
    required this.selectedId,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final bool supported;
  final String unsupportedCaption;
  final List<AudioDevice> devices;
  final String? selectedId;
  final ValueChanged<AudioDevice?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!supported) {
      return AppCallout(
        tone: AppCalloutTone.info,
        icon: icon,
        child: Text('$label: $unsupportedCaption'),
      );
    }

    final tokens = Theme.of(context).extension<AppTokens>()!;
    final resolved = resolveAudioDevice(devices, selectedId);
    final unplugged = selectedId != null && resolved == null;

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
          onChanged: (id) => onChanged(
            id == _systemDefaultId
                ? null
                : devices.firstWhere((d) => d.id == id),
          ),
        ),
        if (unplugged)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s8,
              AppSpacing.s4,
              AppSpacing.s8,
              0,
            ),
            child: Text(
              'Your chosen ${label.toLowerCase()} is not currently '
              'connected; using the system default instead.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
      ],
    );
  }
}
