// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One search or trending result in the GIF picker grid.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/animation_gate.dart';
import '../../../widgets/image_decode.dart';
import '../providers/gif_preview_bytes.dart';

class GifTile extends ConsumerStatefulWidget {
  const GifTile({
    super.key,
    required this.result,
    required this.busy,
    required this.selecting,
    required this.onTap,
    required this.channelId,
  });

  final api.GifResult result;
  final String? channelId;

  /// Whether *some* tile in the grid is currently being picked - every tile
  /// is disabled while that is true, not only the one selected.
  final bool busy;
  final bool selecting;
  final VoidCallback onTap;

  @override
  ConsumerState<GifTile> createState() => GifTileState();
}

class GifTileState extends ConsumerState<GifTile> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    super.dispose();
  }

  // Without this a switch between mouse and keyboard leaves the ring as it was until the next focus change.
  void _onHighlightMode(FocusHighlightMode _) {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final result = widget.result;
    final preview = ref.watch(
      gifPreviewBytesProvider((gifId: result.id, channelId: widget.channelId)),
    );
    // Keyboard focus only: a tap focuses too, and a ring on every tap would flash.
    final ringed =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return Semantics(
      button: true,
      label: result.title.isEmpty ? 'Pick a GIF' : 'Pick: ${result.title}',
      child: InkWell(
        onTap: widget.busy ? null : widget.onTap,
        onFocusChange: (focused) => setState(() => _focused = focused),
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.control),
              child: ColoredBox(
                color: tokens.surfaceBase,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    switch (preview) {
                      AsyncData(value: final Uint8List bytes) => AnimationGate(
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          cacheWidth: decodeEdge(context, 160),
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                      AsyncError() => const SizedBox.shrink(),
                      _ => const Center(
                        child: AppSpinner(size: AppSpinnerSize.sm),
                      ),
                    },
                    if (widget.selecting)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: tokens.surfaceBase.withValues(alpha: 0.65),
                        ),
                        child: const Center(
                          child: AppSpinner(size: AppSpinnerSize.md),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (ringed)
              IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('gif-tile-focus-ring'),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    border: Border.all(
                      color: tokens.focusRing,
                      width: focusRingWidth,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
