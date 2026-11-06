// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tallest camera quality the last camera used has shown it can deliver,
/// kept across launches so Voice settings can grey out what it cannot reach.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/providers.dart';
import 'voice_settings_storage.dart';

typedef CameraReach = ({String deviceId, int height});

class CameraReachNotifier extends Notifier<CameraReach?> {
  @override
  CameraReach? build() {
    void onReading() {
      final reading = localCameraReach.value;
      if (reading != null) _take(reading);
    }

    localCameraReach.addListener(onReading);
    ref.onDispose(() => localCameraReach.removeListener(onReading));
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    final prefs = await ref.read(preferencesProvider.future);
    final stored = prefs.getString(VoiceSettingKeys.cameraReach);
    final at = stored?.lastIndexOf('|') ?? -1;
    if (stored == null || at < 0) return;
    final height = int.tryParse(stored.substring(at + 1));
    if (height == null) return;
    state = (deviceId: stored.substring(0, at), height: height);
  }

  Future<void> _take(CameraReachReading reading) async {
    final next = nextCameraReach(known: state, reading: reading);
    if (next == state) return;
    state = next;
    final prefs = await ref.read(preferencesProvider.future);
    if (next == null) {
      await prefs.remove(VoiceSettingKeys.cameraReach);
    } else {
      await prefs.setString(
        VoiceSettingKeys.cameraReach,
        '${next.deviceId}|${next.height}',
      );
    }
  }
}

final cameraReachProvider = NotifierProvider<CameraReachNotifier, CameraReach?>(
  CameraReachNotifier.new,
);

/// Why [quality] is out of reach for the camera last used, or null when it is not known to be.
String? cameraQualityOutOfReach(CameraQuality quality, CameraReach? reach) {
  if (reach == null || quality == CameraQuality.values.first) return null;
  final height = quality.params.dimensions.height;
  return height > reach.height
      ? 'Your camera tops out at ${reach.height}p'
      : null;
}

/// [chosen], or the tallest quality the camera reaches when the choice is beyond it.
CameraQuality effectiveCameraQuality(CameraQuality chosen, CameraReach? reach) {
  if (cameraQualityOutOfReach(chosen, reach) == null) return chosen;
  return CameraQuality.values.lastWhere(
    (q) => cameraQualityOutOfReach(q, reach) == null,
  );
}

/// Said under the pick when some qualities are out of reach, so touch shows what hover shows.
String? cameraReachNote(CameraReach? reach) =>
    CameraQuality.values.any((q) => cameraQualityOutOfReach(q, reach) != null)
    ? 'Your camera tops out at ${reach!.height}p.'
    : null;
