// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fetch behind the avatar, banner and linked-picture providers.
///
/// A picture that failed once must not stay blank for the session: the
/// keep-alive cache would otherwise hold the error until enough other
/// pictures evicted it.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/cache_for.dart';
import '../../messages/providers/attachment_bytes.dart';

/// The server's answer that the user has no such picture.
class _NoPicture implements Exception {
  const _NoPicture(this.cause, this.stack);

  final NotFoundException cause;
  final StackTrace stack;
}

/// The picture's bytes, or null when the server says the user has none.
///
/// A transient failure is retried a few times, then thrown with [cache] no
/// longer holding [key] so the next view asks again.
Future<Uint8List?> fetchProfileMedia(
  Ref ref,
  Future<FetchedBytes> Function() fetch, {
  required KeepAliveCache cache,
  required Object key,
  required String noneMessage,
}) async {
  var disposed = false;
  ref.onDispose(() => disposed = true);
  try {
    return await fetchAttachmentRetrying(
      ref,
      () async {
        try {
          return await fetch();
        } on NotFoundException catch (error, stack) {
          // Only a 404 the server explained is "no picture"; a bare one may be a proxy mid-restart.
          if (error.unexplained) rethrow;
          throw _NoPicture(error, stack);
        }
      },
      isDisposed: () => disposed,
      onGiveUp: () => cache.release(key),
    );
  } on _NoPicture catch (none) {
    AppLog.swallowed(LogTag.media, noneMessage, none.cause, none.stack);
    return null;
  }
}
