// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('a GIF favorite reads without any attachment fields', () {
    final favorite = Favorite.fromJson({
      'id': 'f1',
      'kind': 'gif',
      'title': 'a cat',
      'width': 498,
      'height': 373,
      'available': true,
      'created_at': 7,
    });
    expect(favorite.isGif, isTrue);
    expect(favorite.attachmentId, isNull);
    expect(favorite.messageId, isNull);
    expect(favorite.width, 498);
  });

  test('an unavailable attachment favorite carries no message or channel', () {
    final favorite = Favorite.fromJson({
      'id': 'f2',
      'kind': 'attachment',
      'title': 'photo.png',
      'width': 0,
      'height': 0,
      'available': false,
      'created_at': 8,
      'attachment_id': 'ab' * 32,
      'content_type': 'image/png',
    });
    expect(favorite.kind, FavoriteKind.attachment);
    expect(favorite.available, isFalse);
    expect(favorite.attachmentId, 'ab' * 32);
    expect(favorite.messageId, isNull);
    expect(favorite.channelId, isNull);
  });
}
