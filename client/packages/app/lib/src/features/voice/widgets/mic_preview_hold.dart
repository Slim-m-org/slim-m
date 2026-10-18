// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screen side of the microphone preview: it runs while one is mounted.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mic_preview.dart';

/// Keeps the preview capture open while it is mounted.
class MicPreviewHold extends ConsumerStatefulWidget {
  const MicPreviewHold({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MicPreviewHold> createState() => _MicPreviewHoldState();
}

class _MicPreviewHoldState extends ConsumerState<MicPreviewHold> {
  late final MicPreviewController _controller = ref.read(
    micPreviewProvider.notifier,
  );

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() {
      if (mounted) _controller.acquire();
    });
  }

  @override
  void dispose() {
    final controller = _controller;
    scheduleMicrotask(() {
      if (controller.mounted) controller.release();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
