// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A shared file as the composer's staging reads it.
library;

import 'dart:io';

import '../../composer/widgets/composer_attachments.dart';
import '../../composer/widgets/file_source_io.dart';
import '../providers/incoming_share.dart';

/// Reads [shared] from the app cache copy the platform made when it arrived.
FileSource sharedFileSource(SharedFile shared) =>
    fileSourceOf(File(shared.path), name: shared.name);
