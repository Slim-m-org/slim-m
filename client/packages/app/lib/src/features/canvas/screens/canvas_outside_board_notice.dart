// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Says how many objects sit past the board's edge, hidden from everyone, and
/// offers to bring them back on. Decision 0080.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class CanvasOutsideBoardNotice extends StatelessWidget {
  const CanvasOutsideBoardNotice({
    super.key,
    required this.document,
    required this.tokens,
    required this.onBringIn,
  });

  final CanvasDocument document;
  final AppTokens tokens;
  final VoidCallback onBringIn;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: document.outsideBoardCount,
    builder: (context, count, _) {
      if (count == 0) return const SizedBox.shrink();
      final label = '$count outside the board';
      return Padding(
        padding: const EdgeInsets.only(left: AppSpacing.s8),
        child: Semantics(
          container: true,
          button: true,
          label: '$label, bring ${count == 1 ? 'it' : 'them'} in',
          excludeSemantics: true,
          onTap: onBringIn,
          child: Material(
            color: tokens.surfaceRaised,
            shape: StadiumBorder(side: BorderSide(color: tokens.borderSubtle)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onBringIn,
              child: SizedBox(
                height: AppSizes.icon28,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s12,
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      '$label - bring in',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                        fontWeight: AppWeights.medium,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
