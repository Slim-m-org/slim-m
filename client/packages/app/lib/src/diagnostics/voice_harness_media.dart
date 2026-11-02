// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Starts a screen share or the camera at launch for the encode readback harness; only reachable through the voice harness build.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/providers/voice_controller.dart';
import '../features/voice/providers/voice_settings_controller.dart';
import 'debug_log.dart';

const _shareFlag = '--voice-harness-share=';
const _cameraFlag = '--voice-harness-camera=';
const _ceilingFlag = '--voice-harness-share-ceiling=';

String? _flag(List<String> args, String prefix) {
  for (final arg in args) {
    if (arg.startsWith(prefix)) return arg.substring(prefix.length);
  }
  return null;
}

/// The tier from `--voice-harness-share=<height>p<fps>`, such as `1080p30`.
ScreenShareQuality? harnessShareQuality(List<String> args) =>
    ScreenShareQuality.fromId(_flag(args, _shareFlag));

/// The camera setting from `--voice-harness-camera=<dataSaver|balanced|high>`.
CameraQuality? harnessCameraQuality(List<String> args) {
  final raw = _flag(args, _cameraFlag);
  for (final q in CameraQuality.values) {
    if (q.name == raw) return q;
  }
  return null;
}

/// The space ceiling in pixels of height from `--voice-harness-share-ceiling=`.
int? harnessShareCeiling(List<String> args) =>
    int.tryParse(_flag(args, _ceilingFlag) ?? '');

/// Publishes what the flags ask for and prints one line per layer per sample.
Future<void> startHarnessMedia(
  ProviderContainer Function() container,
  List<String> args,
) async {
  final voice = container().read(voiceControllerProvider.notifier);
  var echoedUntil = DateTime.now();
  container().listen(debugLogProvider, (_, events) {
    for (final e in events.where((e) => e.at.isAfter(echoedUntil))) {
      if (e.source == 'voice') debugPrint('SLIMM_HARNESS log ${e.message}');
    }
    echoedUntil = DateTime.now();
  });
  voice.callStats.setHeld(true);
  voice.callStats.snapshots.listen((samples) {
    for (final s in samples.where((s) => s.local)) {
      for (final l in s.streams) {
        debugPrint(
          'SLIMM_HARNESS encode source=${s.source.name} rid=${l.rid} '
          'w=${l.width} h=${l.height} fps=${l.fps?.toStringAsFixed(1)} '
          'bps=${l.bitrateBps?.round()} target=${l.targetBitrateBps?.round()} '
          'limit=${l.limitationReason}',
        );
      }
    }
  });
  final share = harnessShareQuality(args);
  if (share != null) {
    await voice.share.setScreenShare(
      true,
      quality: share,
      maxHeight: harnessShareCeiling(args),
    );
    debugPrint('SLIMM_HARNESS share started ${share.id}');
  }
  final camera = harnessCameraQuality(args);
  if (camera != null) {
    await container()
        .read(voiceSettingsControllerProvider.notifier)
        .setCameraQuality(camera);
    await voice.toggleCamera();
    debugPrint('SLIMM_HARNESS camera started ${camera.name}');
  }
}
