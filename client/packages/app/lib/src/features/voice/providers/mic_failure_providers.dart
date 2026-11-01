// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone's failure cause as providers, for the call and the meter.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'mic_failure_advice.dart';
import 'mic_preview.dart';
import 'voice_controller.dart';

/// How a settings link opens, replaceable in tests.
final micSettingsLauncherProvider = Provider<SettingsLauncher>(
  (ref) => launchSettingsPage,
);

/// The cause the microphone last failed for, null while it works.
final micFailureProvider = StreamProvider<MicFailureReason?>((ref) {
  final controller = ref.watch(voiceControllerProvider.notifier);
  return Stream<MicFailureReason?>.multi((out) {
    out.add(controller.devices.micFailure);
    final sub = controller.devices.micFailures.listen(out.add);
    out.onCancel = sub.cancel;
  });
});

/// The microphone the call switched to after the first went silent; null once dismissed.
final micFallbackNoticeProvider = StreamProvider<String?>((ref) {
  final controller = ref.watch(voiceControllerProvider.notifier);
  return Stream<String?>.multi((out) {
    out.add(controller.devices.micFallbackNotice);
    final sub = controller.devices.micFallbackNotices.listen(out.add);
    out.onCancel = sub.cancel;
  });
});

/// What the Voice settings meter says when it cannot open the microphone.
final micPreviewAdviceProvider = FutureProvider<MicAdvice?>((ref) async {
  final status = ref.watch(micPreviewProvider.select((r) => r.status));
  if (status != MicPreviewStatus.unavailable) return null;
  // A browser always names a refusal; elsewhere it shows up as silence.
  const base = kIsWeb
      ? MicFailureReason.permissionDenied
      : MicFailureReason.silent;
  return micAdviceFor(await refineMicFailure(base, osBlocksMicrophone));
});
