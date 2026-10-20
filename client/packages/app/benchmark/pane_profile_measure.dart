// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Frame timing capture around one scripted scenario.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../voice_canvas/benchmark/perf_support.dart';

List<ui.FrameTiming>? frameSink;
List<double>? handlerSamples;

Future<Map<String, Object>> measure(
  String name,
  Future<void> Function() body,
) async {
  frameSink = <ui.FrameTiming>[];
  handlerSamples = <double>[];
  await body();
  await Future<void>.delayed(const Duration(milliseconds: 800));
  final frames = frameSink!;
  final handler = handlerSamples!;
  frameSink = null;
  handlerSamples = null;
  final usable = frames.skip(frames.length > 30 ? 10 : 0).toList();
  Dist us(Duration Function(ui.FrameTiming) pick) =>
      Dist(usable.map((t) => pick(t).inMicroseconds.toDouble()));
  final build = us((t) => t.buildDuration);
  final raster = us((t) => t.rasterDuration);
  final total = us((t) => t.totalSpan);
  String ms(double v) => (v / 1000).toStringAsFixed(2);
  debugPrint(
    '${name.padRight(52)} frames ${usable.length.toString().padLeft(4)}  '
    'build med ${ms(build.median)} p99 ${ms(build.p99)} max ${ms(build.max)}  '
    'raster med ${ms(raster.median)} p99 ${ms(raster.p99)}  '
    'total p99 ${ms(total.p99)} max ${ms(total.max)}  '
    '>16.7 total ${(total.over(budget60Us) * 100).toStringAsFixed(1)}%',
  );
  return <String, Object>{
    'name': name,
    'frames': usable.length,
    'build': build.toJson(),
    'raster': raster.toJson(),
    'total': total.toJson(),
    if (handler.length > 10) 'handler': Dist(handler.skip(10)).toJson(),
  };
}
