// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Says once, above the call, that the canvas the viewer had open was turned off (desktop-vs-mobile.md rule 6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/status_banner.dart';
import '../providers/canvas_entry.dart';
import '../providers/canvas_open.dart';

/// Hands the pane back to the call when its open canvas goes away, and keeps a banner above [child] saying why.
class CanvasTurnedOffNotice extends ConsumerStatefulWidget {
  const CanvasTurnedOffNotice({
    super.key,
    required this.channelId,
    required this.child,
  });

  final String channelId;
  final Widget child;

  @override
  ConsumerState<CanvasTurnedOffNotice> createState() =>
      _CanvasTurnedOffNoticeState();
}

class _CanvasTurnedOffNoticeState extends ConsumerState<CanvasTurnedOffNotice> {
  bool _shown = false;

  @override
  void didUpdateWidget(covariant CanvasTurnedOffNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId) _shown = false;
  }

  void _onCanvasChanged(bool? was, bool has) {
    final open = ref.read(canvasOpenProvider) == widget.channelId;
    if (was != true || has || !open) return;
    // Forgotten here so the board does not come back open if it is turned on again later.
    ref.read(canvasOpenProvider.notifier).state = null;
    setState(() => _shown = true);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(channelHasCanvasProvider(widget.channelId), _onCanvasChanged);
    return Column(
      children: [
        if (_shown)
          StatusBanner(
            message: 'The canvas was turned off for this channel.',
            margin: const EdgeInsets.all(AppSpacing.s8),
            onDismiss: () {
              if (mounted) setState(() => _shown = false);
            },
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
