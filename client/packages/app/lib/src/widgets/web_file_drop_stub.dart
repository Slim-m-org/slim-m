// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The non-web half of `web_file_drop.dart`: never mounted, because only a
/// browser takes its drops from this widget.
library;

import 'package:desktop_drop/desktop_drop.dart' show DropItem;
import 'package:flutter/widgets.dart';

class WebFileDropTarget extends StatelessWidget {
  const WebFileDropTarget({
    super.key,
    required this.enable,
    required this.onEntered,
    required this.onUpdated,
    required this.onExited,
    required this.onDone,
    required this.child,
  });

  final bool enable;
  final ValueChanged<Offset> onEntered;
  final ValueChanged<Offset> onUpdated;
  final VoidCallback onExited;
  final void Function(List<DropItem> files, Offset global, Offset local) onDone;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
