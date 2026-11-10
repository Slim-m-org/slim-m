// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A shared file as the composer's staging reads it.
library;

import 'dart:io';

import '../../composer/widgets/composer_attachments.dart';
import '../providers/incoming_share.dart';

/// Reads [shared] from the app cache copy the platform made when it arrived.
FileSource sharedFileSource(SharedFile shared) {
  final file = File(shared.path);
  return FileSource(
    name: shared.name,
    length: file.length,
    readAll: file.readAsBytes,
    openRead: file.openRead,
    openReadAt: (offset) => file.openRead(offset),
  );
}
