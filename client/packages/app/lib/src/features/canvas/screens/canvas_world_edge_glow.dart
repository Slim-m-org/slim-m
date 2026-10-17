// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The only feedback a person gets that a pan or a tile drag stopped
/// because the bounded world ended (`worldLimit`), not because something
/// broke - a brief accent border along the pane while either
/// [CanvasDocument.worldEdgeHit] or [CanvasPresenceTileOverrides
/// .worldEdgeHit] is true. See both fields' own docs for exactly when each
/// flips.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class CanvasWorldEdgeGlow extends StatelessWidget {
  const CanvasWorldEdgeGlow({
    super.key,
    required this.document,
    required this.tileOverrides,
    required this.tokens,
  });

  final CanvasDocument document;
  final CanvasPresenceTileOverrides tileOverrides;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      document.worldEdgeHit,
      tileOverrides.worldEdgeHit,
    ]),
    builder: (context, _) {
      final atEdge =
          document.worldEdgeHit.value || tileOverrides.worldEdgeHit.value;
      return Positioned.fill(
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: AnimatedOpacity(
              opacity: atEdge ? 1 : 0,
              duration: AppMotion.reduced(context, AppMotion.fast),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: tokens.accentFill, width: 3),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
