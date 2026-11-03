// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The last few custom colours picked on the canvas, kept on this device.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import '../../../providers/preference_controller.dart';
import '../../../providers/providers.dart' show preferencesProvider;

const canvasRecentColoursKey = 'slimm.canvas.recent_colours';
const canvasRecentColoursMax = 5;

/// `#rrggbb` strings, newest first.
class CanvasRecentColours extends StateNotifier<List<String>>
    implements RestorablePreference {
  CanvasRecentColours(this.ref) : super(const []);

  final Ref ref;

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final stored = prefs.getStringList(canvasRecentColoursKey) ?? const [];
      state = [
        for (final hex in stored)
          if (RegExp(r'^#[0-9a-f]{6}$').hasMatch(hex)) hex,
      ].take(canvasRecentColoursMax).toList();
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'Could not read the recent canvas colours; using none',
        error,
        stack,
      );
    }
  }

  /// Moves [hex] to the front, dropping the oldest past the limit.
  Future<void> remember(String hex) async {
    state = [
      hex,
      ...state.where((h) => h != hex),
    ].take(canvasRecentColoursMax).toList();
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setStringList(canvasRecentColoursKey, state);
  }
}

final canvasRecentColoursProvider =
    StateNotifierProvider<CanvasRecentColours, List<String>>(
      CanvasRecentColours.new,
    );
