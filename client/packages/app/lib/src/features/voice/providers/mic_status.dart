// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the microphone is healthy, reconnecting or given up on, for the
/// mute buttons to say so next to themselves.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller.dart';

final micStatusProvider = StreamProvider<MicStatus>((ref) {
  final controller = ref.watch(voiceControllerProvider.notifier);
  return Stream<MicStatus>.multi((out) {
    out.add(controller.devices.micStatus);
    final sub = controller.devices.micStatuses.listen(out.add);
    out.onCancel = sub.cancel;
  });
});

extension MicStatusLabels on MicStatus {
  /// Replaces the mute button's own label while the mic is not healthy.
  String? get trouble => switch (this) {
    MicStatus.ok => null,
    MicStatus.reconnecting => 'Microphone reconnecting',
    MicStatus.unavailable => 'Microphone unavailable, tap to retry',
  };
}
