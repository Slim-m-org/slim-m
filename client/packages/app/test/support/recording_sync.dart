// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A sync controller that never connects and writes down the canvas view and
/// cursor frames the app would have sent.
library;

import 'fake_sync.dart';

typedef SentView = ({
  double x,
  double y,
  double w,
  double h,
  bool summon,
  String? tile,
});

class RecordingSyncController extends NoopSyncController {
  RecordingSyncController(super.ref);

  static final List<SentView> views = [];
  static final List<({double x, double y, bool left})> cursors = [];

  static void clear() {
    views.clear();
    cursors.clear();
  }

  @override
  void notifyCanvasView(
    String channelId,
    ({double x, double y, double w, double h}) view, {
    bool summon = false,
    String? tile,
  }) => views.add((
    x: view.x,
    y: view.y,
    w: view.w,
    h: view.h,
    summon: summon,
    tile: tile,
  ));

  @override
  void notifyCanvasCursor(
    String channelId,
    double x,
    double y, {
    bool left = false,
  }) => cursors.add((x: x, y: y, left: left));
}
