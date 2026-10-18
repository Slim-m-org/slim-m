// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel rail's width, which a drag on its edge sets anywhere between
/// [railMinWidth] and [railMaxWidth] and which survives a restart.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/preference_controller.dart';
import '../../../providers/providers.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const railWidthKey = 'slimm.layout.rail_width';

/// The narrowest the rail drags to: the compact width, where every channel name still fits.
const double railMinWidth = 200;

/// The widest the rail drags to, leaving the conversation the room it needs.
const double railMaxWidth = 360;

double clampRailWidth(double width) =>
    width.clamp(railMinWidth, railMaxWidth).toDouble();

/// Null until someone drags the edge, which keeps each layout's own default.
class RailWidthController extends StateNotifier<double?>
    implements RestorablePreference {
  RailWidthController(this._ref) : super(null);

  final Ref _ref;

  @override
  Future<void> restore() async {
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      final stored = prefs.getDouble(railWidthKey);
      if (stored != null && stored.isFinite) state = clampRailWidth(stored);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'Could not read the saved sidebar width; using the default',
        error,
        stack,
      );
    }
  }

  /// Follows the pointer during a drag without writing to storage each frame.
  void preview(double width) => state = clampRailWidth(width);

  /// Stores the width the drag ended on.
  Future<void> commit() async {
    final width = state;
    if (width == null) return;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setDouble(railWidthKey, width);
  }
}

final railWidthControllerProvider =
    StateNotifierProvider<RailWidthController, double?>(
      RailWidthController.new,
    );

/// Whether the rail's edge is being dragged right now, so the rail follows
/// the pointer instead of animating toward it.
final railDraggingProvider = StateProvider<bool>((ref) => false);
