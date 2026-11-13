// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Screen shares the way the app starts them: reset, enumerate, capture.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const _channel = MethodChannel('FlutterWebRTC.Method');

Future<void> share(int n, {bool enumerate = true}) async {
  var id = '0';
  if (enumerate) {
    await _channel.invokeMethod<void>('resetDesktopSources');
    final sources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
    );
    stdout.writeln('PROBE share $n sources=${sources.length}');
    id = sources.first.id;
  }
  final stream = await navigator.mediaDevices.getDisplayMedia({
    'video': {
      'deviceId': {'exact': id},
      'mandatory': {'frameRate': 30},
    },
    'audio': false,
  });
  stdout.writeln('PROBE share $n tracks=${stream.getVideoTracks().length}');
  final picked = await _channel.invokeMethod<Object?>('portalStreamGeometry');
  stdout.writeln('PROBE share $n monitor=$picked');
  await Future<void>.delayed(const Duration(seconds: 2));
  for (final track in stream.getTracks()) {
    await track.stop();
  }
  await stream.dispose();
}

Future<void> expectRefusal(Future<Object?> Function() call) async {
  try {
    await call();
    stdout.writeln('PROBE refusal=none');
  } on Object catch (error) {
    stdout.writeln('PROBE refusal=$error');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
  await Future<void>.delayed(const Duration(seconds: 2));
  switch (Platform.environment['PROBE_MODE']) {
    case 'long':
      await share(1);
      await Future<void>.delayed(const Duration(seconds: 35));
      await share(2);
      await share(3);
    case 'window':
      await _channel.invokeMethod<void>('resetDesktopSources');
      final windows = await desktopCapturer.getSources(
        types: [SourceType.Window],
      );
      stdout.writeln('PROBE windows=${windows.length}');
    case 'nosession':
      await _channel.invokeMethod<void>('resetDesktopSources');
      final listed = await desktopCapturer.getSources(
        types: [SourceType.Screen, SourceType.Window],
      );
      stdout.writeln('PROBE listed=${listed.length}');
    case 'noaudio':
      await expectRefusal(() => createPeerConnection(<String, dynamic>{}));
      await expectRefusal(
        () => navigator.mediaDevices.getUserMedia({'audio': true}),
      );
    case 'noenum':
      await share(1, enumerate: false);
    default:
      await share(1);
      await share(2);
  }
  stdout.writeln('PROBE done');
  exit(0);
}
