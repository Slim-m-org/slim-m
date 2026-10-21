// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A quiet count of how much of a big board has arrived while the rest pages in.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_board_pager.dart' show CanvasPaging;

class CanvasPagingIndicator extends StatelessWidget {
  const CanvasPagingIndicator({super.key, required this.paging});

  final CanvasPaging paging;

  String get _label {
    final total = paging.total;
    return total == null
        ? '${paging.loaded} objects loaded'
        : '${paging.loaded} / $total objects';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.s8),
        child: IgnorePointer(
          child: Semantics(
            liveRegion: false,
            label: 'Loading the rest of the canvas, $_label',
            excludeSemantics: true,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: tokens.surfaceRaised,
                shape: StadiumBorder(
                  side: BorderSide(color: tokens.borderSubtle),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s12,
                  vertical: AppSpacing.s4,
                ),
                child: Text(
                  _label,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
