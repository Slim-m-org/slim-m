// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The callout shown when a viewport page was capped and some ink is not
/// loaded; split from `canvas_pane_body.dart` to keep it under the file
/// budget.
library;

import 'package:flutter/material.dart';

import 'canvas_board_callout.dart';

class CanvasTruncatedNotice extends StatelessWidget {
  const CanvasTruncatedNotice({super.key});

  @override
  Widget build(BuildContext context) => const CanvasBoardCallout(
    'Some ink in this region is not shown. Zoom in to see it.',
  );
}
