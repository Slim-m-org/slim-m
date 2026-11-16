// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Places one stamp on someone's shared screen (decision 0121): shown here at
/// once, sent over REST, and taken back off with a reason if it is refused.
library;

import 'dart:ui' show Offset;

import 'package:slimm_api/api.dart' as api;

import '../../../ids.dart';
import 'screen_annotation_feed.dart';
import 'stamp_content.dart';

class ScreenStampSender {
  ScreenStampSender({
    required this.channelId,
    required this.sharerId,
    required this.selfId,
    required this.client,
    required this.feed,
  });

  final String channelId;
  final String sharerId;
  final String selfId;
  final api.SlimmApi client;
  final ScreenAnnotationFeed feed;

  /// Places [content] centred at [centre] (0 to 1 across the shared screen) with its longest side [size] of the screen's height; the sentence to show when it is refused, or null.
  Future<String?> place(
    StampContent content,
    Offset centre,
    double size,
  ) async {
    final id = newScreenAnnotationId();
    final (emoji, attachment) = switch (content) {
      EmojiStamp(:final key) => (key, null),
      PictureStamp(:final attachmentId) => (null, attachmentId),
    };
    feed.applyLocal(
      api.CanvasScreenAnnotation(
        channelId: channelId,
        userId: selfId,
        targetUserId: sharerId,
        kind: 'stamp',
        annotationId: id,
        points: [centre.dx, centre.dy],
        size: size,
        emoji: emoji,
        attachment: attachment,
        animated: content is PictureStamp && content.animated,
        ended: true,
        allowed: false,
      ),
    );
    try {
      await client.placeScreenStamp(
        channelId,
        id: id,
        targetUserId: sharerId,
        x: centre.dx,
        y: centre.dy,
        size: size,
        emoji: emoji,
        attachmentId: attachment,
      );
      return null;
    } on api.ApiException catch (error) {
      feed.remove(sharerId, id);
      return stampRefusal(error);
    }
  }
}

/// What a refused stamp tells the person who placed it.
String stampRefusal(api.ApiException error) => switch (error) {
  api.RateLimitedException() => 'Wait a moment before stamping again.',
  api.ForbiddenException(:final message) when message.contains('call') =>
    'Join the call to stamp.',
  api.ForbiddenException() => 'You cannot stamp on this screen.',
  api.ConflictException() => 'Their screen is not taking stamps right now.',
  api.BadRequestException(:final message)
      when message.contains('MiB') || message.contains('megapixels') =>
    'That picture is too large to stamp.',
  api.BadRequestException(:final message) when message.contains('frame') =>
    'That GIF cannot be stamped.',
  api.NotFoundException() => 'That picture cannot be stamped.',
  _ => 'That stamp did not go through.',
};
