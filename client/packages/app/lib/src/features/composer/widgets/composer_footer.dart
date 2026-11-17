// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What sits under the composer's action bar: the phone photo strip and the length counter.
library;

import 'package:flutter/material.dart';

import 'staged_attachment_model.dart';
import 'composer_extras.dart';
import 'composer_photo_strip.dart';

class ComposerFooter extends StatelessWidget {
  const ComposerFooter({
    required this.channelId,
    required this.charCount,
    required this.stageFile,
    required this.onBrowse,
    super.key,
  });

  final String channelId;
  final int charCount;
  final Future<void> Function(FileSource file) stageFile;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ComposerPhotoStripSlot(
        channelId: channelId,
        stageFile: stageFile,
        onBrowse: onBrowse,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: MessageLengthCounter(length: charCount),
        ),
      ),
    ],
  );
}
