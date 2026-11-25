// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What `POST /channels/{id}/canvas/export` answers, and the codes of its refusals.
library;

import 'models_channel.dart';

/// What an export of a board made, or what the first try of its id made.
class CanvasExportResult {
  const CanvasExportResult({
    required this.channel,
    required this.copied,
    required this.skipped,
    required this.cleared,
    required this.spared,
    this.left = 0,
  });

  factory CanvasExportResult.fromJson(Map<String, dynamic> json) =>
      CanvasExportResult(
        channel: Channel.fromJson(json['channel'] as Map<String, dynamic>),
        copied: (json['copied'] as num).toInt(),
        skipped: (json['skipped'] as num).toInt(),
        cleared: (json['cleared'] as num).toInt(),
        spared: (json['spared'] as num).toInt(),
        left: (json['left'] as num?)?.toInt() ?? 0,
      );

  final Channel channel;

  /// Objects copied into [channel], connectors included.
  final int copied;

  /// Objects left behind: connectors that lost an end, tiles of missing modules.
  final int skipped;

  /// Objects removed from the source; 0 unless it was cleared.
  final int cleared;

  /// Locked objects a clear left on the source.
  final int spared;

  /// Objects that could not be copied and so stayed on the source, which a clear spared; 0 from an older server.
  final int left;
}

/// The `code` values of an export's 409 refusals; mirror `http/canvas/canvas_export.rs`.
abstract final class CanvasExportRefusal {
  static const tooLarge = 'canvas_export_too_large';
  static const busy = 'canvas_export_busy';
}
