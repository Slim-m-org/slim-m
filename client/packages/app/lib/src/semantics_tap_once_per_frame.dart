// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lets one semantics tap per node through each frame.
///
/// A button only disables itself, and a popped route only leaves the semantics
/// tree, on the next frame. A second tap on the same node before then runs the
/// handler again against stale state: a sheet's Send pops twice and takes the
/// page beneath it, leaving a blank app.
library;

import 'dart:ui' show PlatformDispatcher, SemanticsActionEvent;

import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;

class SemanticsTapOncePerFrame {
  SemanticsTapOncePerFrame(this._forward, this._scheduler);

  final void Function(SemanticsActionEvent) _forward;
  final SchedulerBinding _scheduler;
  final _tappedThisFrame = <(int, int)>{};

  /// Wraps the binding's own handler, which must already be installed.
  static void install(PlatformDispatcher dispatcher, SchedulerBinding binding) {
    final forward = dispatcher.onSemanticsActionEvent;
    if (forward == null) return;
    dispatcher.onSemanticsActionEvent = SemanticsTapOncePerFrame(
      forward,
      binding,
    ).handle;
  }

  void handle(SemanticsActionEvent event) {
    if (event.type == SemanticsAction.tap) {
      final firstThisFrame = _tappedThisFrame.isEmpty;
      if (!_tappedThisFrame.add((event.viewId, event.nodeId))) return;
      if (firstThisFrame) {
        _scheduler.addPostFrameCallback((_) => _tappedThisFrame.clear());
        _scheduler.scheduleFrame();
      }
    }
    _forward(event);
  }
}
