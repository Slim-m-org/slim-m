// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'canvas_board_pager.dart';

/// [CanvasEngine.state]'s own shape: the three fields that used to be plain
/// `setState`-driven fields on `_CanvasPaneState` and still need to trigger a
/// rebuild when they change. Everything else the engine owns is a
/// `Listenable`/`ChangeNotifier` of its own, painted straight from
/// `CanvasPaneBody` without going through this at all.
class CanvasEngineState {
  const CanvasEngineState({
    this.loading = true,
    this.error,
    this.truncated = false,
    this.paging,
  });

  final bool loading;
  final String? error;
  final bool truncated;

  /// How much of the board has arrived while the rest is still being read, or
  /// null once the whole board is here.
  final CanvasPaging? paging;

  CanvasEngineState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    bool? truncated,
    CanvasPaging? paging,
    bool clearPaging = false,
  }) => CanvasEngineState(
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    truncated: truncated ?? this.truncated,
    paging: clearPaging ? null : (paging ?? this.paging),
  );
}
