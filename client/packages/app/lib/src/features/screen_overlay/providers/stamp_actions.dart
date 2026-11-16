// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the stamp widgets ask of the server (decision 0121), kept with the
/// data layer: upload a picture, place a stamp, list the pictures received.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import 'screen_annotation_feed.dart';
import 'screen_stamp_sender.dart';
import 'stamp_content.dart';
import 'stamp_images.dart';
import 'stamp_picture_upload.dart';

class StampActions {
  StampActions(this._ref);

  final Ref _ref;

  /// Uploads a picked or pasted picture and bakes it; throws [StampPictureRefused].
  Future<PictureStamp> uploadPicture(
    Uint8List bytes, {
    required String filename,
    String? channelId,
  }) => uploadStampPicture(
    _ref.read(apiProvider),
    _ref.read(stampImageCacheProvider),
    bytes,
    filename: filename,
    channelId: channelId,
  );

  /// A sender for stamps from [selfId] on [sharerId]'s screen in [channelId].
  ScreenStampSender sender({
    required String channelId,
    required String sharerId,
    required String selfId,
    required ScreenAnnotationFeed feed,
  }) => ScreenStampSender(
    channelId: channelId,
    sharerId: sharerId,
    selfId: selfId,
    client: _ref.read(apiProvider),
    feed: feed,
  );
}

final stampActionsProvider = Provider<StampActions>(StampActions.new);

/// The pictures stamped on the caller's screen in the last day, newest first.
final receivedScreenStampsProvider =
    FutureProvider.autoDispose<List<api.ReceivedScreenStamp>>(
      (ref) => ref.watch(apiProvider).listReceivedScreenStamps(),
    );
