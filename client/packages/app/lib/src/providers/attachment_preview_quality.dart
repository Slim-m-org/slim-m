// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How sharply an inline attachment preview is decoded, as a user setting.
///
/// The transcript decodes each image or gif attachment down to a preview size
/// to draw it inline; this scales that decode. A lower setting decodes fewer
/// pixels, so each preview holds roughly a quarter (or less) of the resident
/// memory, letting far more of them sit in the decoded-image cache at once -
/// which is the point of pairing it with a larger
/// [imageCacheLimitControllerProvider].
///
/// Only the inline preview is touched. Opening an attachment decodes it at full
/// resolution on its own path (`showFullscreenImage`), so a data-saver preview
/// never means a data-saver look at the thing itself.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'preference_controller.dart';

/// The decode-resolution levels offered for inline attachment previews.
enum AttachmentPreviewQuality { dataSaver, balanced, sharp }

extension AttachmentPreviewQualityX on AttachmentPreviewQuality {
  /// Multiplies the edge `decodeEdge` would otherwise pick. Sharp is 1, so the
  /// default changes nothing; the lower levels decode fewer pixels, and memory
  /// falls with the square of this.
  double get decodeScale => switch (this) {
    AttachmentPreviewQuality.dataSaver => 0.5,
    AttachmentPreviewQuality.balanced => 0.72,
    AttachmentPreviewQuality.sharp => 1.0,
  };

  /// The picker label, with the default marked the way the image-cache row is.
  String get label => switch (this) {
    AttachmentPreviewQuality.dataSaver => 'Data saver',
    AttachmentPreviewQuality.balanced => 'Balanced',
    AttachmentPreviewQuality.sharp => 'Sharp (default)',
  };
}

const attachmentPreviewQualityKey = 'slimm.performance.preview_quality';

/// Sharp: the full-resolution decode this app has always done, so leaving the
/// setting alone changes nothing.
const defaultAttachmentPreviewQuality = AttachmentPreviewQuality.sharp;

class AttachmentPreviewQualityController
    extends EnumPreferenceController<AttachmentPreviewQuality> {
  AttachmentPreviewQualityController(super.ref)
    : super(
        storageKey: attachmentPreviewQualityKey,
        choices: AttachmentPreviewQuality.values,
        fallback: defaultAttachmentPreviewQuality,
      );
}

final attachmentPreviewQualityControllerProvider =
    StateNotifierProvider<
      AttachmentPreviewQualityController,
      AttachmentPreviewQuality
    >(AttachmentPreviewQualityController.new);
