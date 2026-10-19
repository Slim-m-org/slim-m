// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two screen shares the way the app starts them: reset, enumerate, capture.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const _channel = MethodChannel('FlutterWebRTC.Method');

Future<void> share(int n) async {
  await _channel.invokeMethod<void>('resetDesktopSources');
  final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
  stdout.writeln('PROBE share $n sources=${sources.length}');
  final stream = await navigator.mediaDevices.getDisplayMedia({
    'video': {
      'deviceId': {'exact': sources.first.id},
      'mandatory': {'frameRate': 30},
    },
    'audio': false,
  });
  stdout.writeln('PROBE share $n tracks=${stream.getVideoTracks().length}');
  await Future<void>.delayed(const Duration(seconds: 2));
  for (final track in stream.getTracks()) {
    await track.stop();
  }
  await stream.dispose();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
  await Future<void>.delayed(const Duration(seconds: 2));
  await share(1);
  await share(2);
  stdout.writeln('PROBE done');
  exit(0);
}
