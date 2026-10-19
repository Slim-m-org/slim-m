// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether canvas moves and resizes snap to the grid, per device.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import '../../../providers/providers.dart';

/// The `SharedPreferences` key, in [preferencesProvider].
const canvasSnapToGridKey = 'slimm.canvas.snap_to_grid';

class CanvasGridSnapController extends StateNotifier<bool> {
  CanvasGridSnapController(this._ref) : super(false) {
    ready = _load();
  }

  final Ref _ref;
  int _generation = 0;

  /// Resolves once the stored choice, if any, has been read.
  late final Future<void> ready;

  Future<void> _load() async {
    final generation = _generation;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      if (!mounted || generation != _generation) return;
      state = prefs.getBool(canvasSnapToGridKey) ?? false;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not read the snap to grid setting; leaving it off',
        error,
        stack,
      );
    }
  }

  Future<void> toggle() async {
    await ready;
    _generation++;
    state = !state;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      await prefs.setBool(canvasSnapToGridKey, state);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not save the snap to grid setting; applied for this session only',
        error,
        stack,
      );
    }
  }
}

/// Not `autoDispose`, so reopening a canvas does not flash the stored choice off.
final canvasGridSnapProvider =
    StateNotifierProvider<CanvasGridSnapController, bool>(
      CanvasGridSnapController.new,
    );
