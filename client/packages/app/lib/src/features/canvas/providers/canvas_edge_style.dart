// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The style a new connection is drawn in, and whether the server draws them at all.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../providers/server_info.dart';

/// What the Connect tool arms: the next connection takes this colour and arrow. A null colour is the board's neutral ink.
@immutable
class CanvasEdgeStyle {
  const CanvasEdgeStyle({this.colorKey, this.arrow = EdgeArrow.end});

  final String? colorKey;
  final EdgeArrow arrow;

  CanvasEdgeStyle copyWith({
    String? colorKey,
    bool clearColor = false,
    EdgeArrow? arrow,
  }) => CanvasEdgeStyle(
    colorKey: clearColor ? null : colorKey ?? this.colorKey,
    arrow: arrow ?? this.arrow,
  );

  @override
  bool operator ==(Object other) =>
      other is CanvasEdgeStyle &&
      other.colorKey == colorKey &&
      other.arrow == arrow;

  @override
  int get hashCode => Object.hash(colorKey, arrow);
}

/// The armed connection style, kept across canvas pane opens.
final canvasActiveEdgeStyleProvider = StateProvider<CanvasEdgeStyle>(
  (ref) => const CanvasEdgeStyle(),
);

/// Whether the server accepts `edge` objects; an older one hides the Connect tool, the side dots and "Connect to...".
final canvasEdgesSupportedProvider = Provider<bool>(
  (ref) => ref.watch(serverInfoProvider).valueOrNull?.canvasEdges ?? false,
);
