// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting row that copies one block describing how a call went,
/// for a bug report. It reads only what the call already logged.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag, redactText;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/providers.dart';
import '../../../providers/toasts.dart';
import '../../voice/providers/join_timings_provider.dart';
import '../../voice/providers/voice_controller.dart';
import 'settings_detail_row.dart';

/// The report as text: this install, the devices, then the call's numbers.
Future<String> callDiagnosticsText(WidgetRef ref) async {
  final controller = ref.read(voiceControllerProvider.notifier);
  final version = await _appVersion(ref);
  final facts = {
    'App': 'slim-m ${version ?? 'unknown version'}',
    'Platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    'Microphone': await _deviceLabel(
      controller.devices.audioInputDevices,
      controller.devices.audioInputInUse,
    ),
    'Speaker': await _deviceLabel(
      controller.devices.audioOutputDevices,
      controller.devices.audioOutputInUse,
    ),
  };
  final report = controller.diagnostics.report(
    facts: facts,
    joinLine: ref.read(joinTimingsProvider).last?.line,
  );
  return redactText(report);
}

Future<String?> _appVersion(WidgetRef ref) async {
  try {
    return (await ref.read(appInfoProvider.future)).version;
  } on Object catch (error, stack) {
    AppLog.swallowed(LogTag.ui, 'No app version for the report', error, stack);
    return null;
  }
}

Future<String> _deviceLabel(
  Future<List<AudioDevice>> Function() list,
  String? inUseId,
) async {
  if (inUseId == null) return 'system default';
  try {
    final match = (await list()).where((d) => d.id == inUseId).firstOrNull;
    return match == null || match.label.isEmpty
        ? 'unnamed device'
        : match.label;
  } on Object catch (error, stack) {
    AppLog.swallowed(LogTag.ui, 'No device list for the report', error, stack);
    return 'unknown';
  }
}

class CallDiagnosticsRow extends ConsumerWidget {
  const CallDiagnosticsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsDetailRow(
      icon: AppIcons.copy,
      title: 'Copy call diagnostics',
      detail: 'Audio and video numbers to paste into a bug report.',
      onTap: () => unawaited(_copy(context, ref)),
    );
  }

  Future<void> _copy(BuildContext context, WidgetRef ref) async {
    final text = await callDiagnosticsText(ref);
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    final inCall = ref
        .read(voiceControllerProvider.notifier)
        .diagnostics
        .active;
    ref
        .read(toastsProvider.notifier)
        .show(
          inCall
              ? 'Call diagnostics copied'
              : 'Call diagnostics copied. No call is active.',
          severity: AppToastSeverity.success,
        );
  }
}
