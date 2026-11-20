// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turns a picked, pasted or dropped picture into a stamp (decision 0121): an
/// ordinary attachment, baked from the bytes in hand so it is not fetched back.
library;

import 'dart:typed_data';

import 'package:slimm_api/api.dart' as api;

import '../../../providers/bounded_image_decode.dart';
import 'stamp_bake.dart';
import 'stamp_content.dart';
import 'stamp_images.dart';

/// The largest picture the server takes as a stamp.
const stampPictureMaxBytes = 8 * 1024 * 1024;

/// The longest side a picture past [stampPictureMaxBytes] is shrunk to: a stamp shows at most a 640 px still.
const stampShrinkEdge = 1024;

/// The file extensions of the picture types the server takes as a stamp.
const stampPictureExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp'];

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
///
/// A picture past the server's cap, a 4K screenshot or a camera photo, goes up
/// shrunk to [stampShrinkEdge] as a PNG rather than being refused.
Future<PictureStamp> uploadStampPicture(
  api.SlimmApi client,
  StampImageCache cache,
  Uint8List original, {
  required String filename,
  String? channelId,
}) async {
  final (bytes, name) = original.length > stampPictureMaxBytes
      ? (await _shrunk(original), _asPng(filename))
      : (original, filename);
  final api.Attachment attachment;
  try {
    attachment = await client.uploadAttachment(
      bytes,
      filename: name,
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

Future<Uint8List> _shrunk(Uint8List bytes) async {
  try {
    final image = await decodeBoundedImage(
      bytes,
      maxSide: stampShrinkEdge,
      maxSourcePixels: stampMaxSourcePixels,
    );
    try {
      return await encodeStampPng(image);
    } finally {
      image.dispose();
    }
  } on ImageTooLargeException {
    throw const StampPictureRefused('That picture is too large to stamp.');
  } on Object catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.media,
      'A large stamp picture would not shrink; the person was told',
      error,
      stack,
    );
    throw const StampPictureRefused('That picture could not be read.');
  }
}

String _asPng(String filename) {
  final dot = filename.lastIndexOf('.');
  return '${dot > 0 ? filename.substring(0, dot) : filename}.png';
}
