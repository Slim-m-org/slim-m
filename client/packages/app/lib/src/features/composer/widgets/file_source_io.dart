// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A local file as the composer's staging reads it.
library;

import 'dart:io';

import 'staged_attachment_model.dart';

/// Reads [file] only when it is staged, streaming it when it is large.
FileSource fileSourceOf(File file, {required String name}) => FileSource(
  name: name,
  length: file.length,
  readAll: file.readAsBytes,
  openRead: file.openRead,
  openReadAt: (offset) => file.openRead(offset),
);
