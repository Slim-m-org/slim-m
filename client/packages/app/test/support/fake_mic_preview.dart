// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A microphone preview over a scripted capture, so a widget test drives the
/// level without a native audio stack.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_app/src/features/voice/providers/mic_preview.dart';
import 'package:slimm_rtc/rtc.dart';

class FakeMicSource implements MicPreviewSource {
  FakeMicSource({this.level = -30.0, this.voice = false, this.fails = false});

  double? level;
  bool voice;
  bool fails;
  final opened = <String?>[];
  int closes = 0;

  @override
  Future<void> open(String? deviceId) async {
    opened.add(deviceId);
    if (fails) throw StateError('no microphone');
  }

  @override
  Future<({double levelDb, bool voice})?> read() async =>
      level == null ? null : (levelDb: level!, voice: voice);

  @override
  Future<void> close() async => closes++;
}

Override fakeMicPreview(FakeMicSource source) =>
    micPreviewFactoryProvider.overrideWithValue(
      () => MicPreview(
        source: source,
        interval: const Duration(milliseconds: 10),
      ),
    );

/// No native capture: the preview never opens, so a snapshot render that lets real time pass cannot reach the WebRTC plugin.
final quietMicPreview = micPreviewFactoryProvider.overrideWithValue(
  () => MicPreview(source: _NeverOpens(), openTimeout: null),
);

class _NeverOpens implements MicPreviewSource {
  @override
  Future<void> open(String? deviceId) => Completer<void>().future;

  @override
  Future<({double levelDb, bool voice})?> read() async => null;

  @override
  Future<void> close() async {}
}
