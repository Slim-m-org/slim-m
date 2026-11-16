// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turns a picked, pasted or dropped picture into a stamp (decision 0121): an
/// ordinary attachment, baked from the bytes in hand so it is not fetched back.
library;

import 'dart:typed_data';

import 'package:slimm_api/api.dart' as api;

import '../../../providers/bounded_image_decode.dart';
import 'stamp_content.dart';
import 'stamp_images.dart';

/// The largest picture the server takes as a stamp.
const stampPictureMaxBytes = 8 * 1024 * 1024;

/// Why a picture did not become a stamp, in a sentence for the person.
class StampPictureRefused implements Exception {
  const StampPictureRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Whether a tile animates [attachment] as a stamp, as the server decides it.
bool stampAnimates(api.Attachment attachment) =>
    attachment.contentType == 'image/gif' &&
    attachment.size <= stampAnimatedMaxBytes;

/// Uploads [bytes] and bakes them into [cache]; throws [StampPictureRefused].
Future<PictureStamp> uploadStampPicture(
  api.SlimmApi client,
  StampImageCache cache,
  Uint8List bytes, {
  required String filename,
  String? channelId,
}) async {
  if (bytes.length > stampPictureMaxBytes) {
    throw const StampPictureRefused('That picture is too large to stamp.');
  }
  final api.Attachment attachment;
  try {
    attachment = await client.uploadAttachment(
      bytes,
      filename: filename,
      channelId: channelId,
    );
  } on api.ApiException catch (error) {
    throw StampPictureRefused(switch (error) {
      api.ServerException(statusCode: 413) =>
        'That picture is too large to stamp.',
      api.ServerException(statusCode: 507) =>
        'This server has no storage left. Tell an admin.',
      api.BadRequestException() => 'That file is not a picture.',
      _ => 'That picture could not be uploaded.',
    });
  }
  final stamp = PictureStamp(
    attachment.id,
    animated: stampAnimates(attachment),
  );
  try {
    await cache.seed(stamp, bytes);
  } on ImageTooLargeException {
    throw const StampPictureRefused('That picture is too large to stamp.');
  } on Object catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.media,
      'A stamp picture would not decode; the person was told',
      error,
      stack,
    );
    throw const StampPictureRefused('That picture could not be read.');
  }
  return stamp;
}
