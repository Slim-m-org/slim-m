// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Synthetic pointer input and the lookups that decide where to press, for the profile run.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'pane_profile_measure.dart';

Future<void> nextFrame() => SchedulerBinding.instance.endOfFrame;

int get viewId => ui.PlatformDispatcher.instance.implicitView!.viewId;

void sendPointer(PointerEvent event) =>
    GestureBinding.instance.handlePointerEvent(event);

void timedSend(PointerEvent event) {
  final sw = Stopwatch()..start();
  sendPointer(event);
  handlerSamples?.add(sw.elapsedMicroseconds.toDouble());
}

PointerDownEvent pointerDown(Offset at, int buttons) => PointerDownEvent(
  viewId: viewId,
  pointer: 31,
  device: 31,
  kind: PointerDeviceKind.mouse,
  position: at,
  buttons: buttons,
);

PointerMoveEvent pointerMove(Offset at, Offset delta, int buttons) =>
    PointerMoveEvent(
      viewId: viewId,
      pointer: 31,
      device: 31,
      kind: PointerDeviceKind.mouse,
      position: at,
      delta: delta,
      buttons: buttons,
    );

PointerUpEvent pointerUp(Offset at) => PointerUpEvent(
  viewId: viewId,
  pointer: 31,
  device: 31,
  kind: PointerDeviceKind.mouse,
  position: at,
);

/// Taps the tool button labelled [label], the way a person selects a tool.
Future<void> selectTool(String label) async {
  RenderBox? button;
  void visit(Element element) {
    if (button != null) return;
    final widget = element.widget;
    if (widget is AppIconButton && widget.semanticLabel == label) {
      button = element.renderObject as RenderBox?;
      return;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  final box = button;
  if (box == null) {
    debugPrint('WARN no tool button labelled $label');
    return;
  }
  final at = box.localToGlobal(box.size.center(Offset.zero));
  sendPointer(pointerDown(at, kPrimaryButton));
  sendPointer(pointerUp(at));
  await nextFrame();
  await nextFrame();
}

RenderBox surfaceBox() {
  RenderBox? found;
  void visit(Element element) {
    if (found != null) return;
    if (element.widget is CanvasSurface) {
      found = element.renderObject! as RenderBox;
      return;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return found!;
}

/// Every call tile's rectangle on screen, which a press must keep clear of.
List<Rect> tileRects() {
  final rects = <Rect>[];
  void visit(Element element) {
    if (element.widget is CanvasPresenceManipulableTile) {
      final box = element.renderObject as RenderBox?;
      if (box != null && box.hasSize) {
        rects.add((box.localToGlobal(Offset.zero) & box.size).inflate(8));
      }
      return;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return rects;
}

/// Whether a press at [at] lands in the drawing surface and not on a call
/// tile, the dock or any other layer stacked over it.
bool hitsSurface(Offset at) {
  if (tileRects().any((r) => r.contains(at))) return false;
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, at, viewId);
  final box = surfaceBox();
  for (final entry in result.path) {
    final target = entry.target;
    if (target is! RenderObject) continue;
    RenderObject? walk = target;
    while (walk != null) {
      if (identical(walk, box)) return true;
      walk = walk.parent;
    }
  }
  return false;
}

/// A press point inside the surface that nothing else covers, nearest the middle.
Offset freeSpot(RenderBox box) {
  final origin = box.localToGlobal(Offset.zero);
  final middle = origin + Offset(box.size.width / 2, box.size.height / 2);
  final candidates = <Offset>[
    for (var dy = -300.0; dy <= 300; dy += 50)
      for (var dx = -500.0; dx <= 500; dx += 50) middle + Offset(dx, dy),
  ]..sort((a, b) => (a - middle).distance.compareTo((b - middle).distance));
  return candidates.firstWhere(hitsSurface, orElse: () => middle);
}
