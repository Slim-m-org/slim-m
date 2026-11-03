// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the one background picture is kept on this device: a file in the
/// application support directory on native, IndexedDB on web.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'background_image_store_web.dart'
    if (dart.library.io) 'background_image_store_io.dart';

/// Holds at most one encoded picture. Reads and writes never throw: a failure
/// reads as no picture.
abstract interface class BackgroundImageStore {
  Future<Uint8List?> read();

  /// Whether [bytes] were kept.
  Future<bool> write(Uint8List bytes);

  Future<void> clear();
}

/// A store that forgets on exit, for tests and for a device that refuses disk.
class MemoryBackgroundImageStore implements BackgroundImageStore {
  Uint8List? _bytes;

  @override
  Future<Uint8List?> read() async => _bytes;

  @override
  Future<bool> write(Uint8List bytes) async {
    _bytes = bytes;
    return true;
  }

  @override
  Future<void> clear() async => _bytes = null;
}

final backgroundImageStoreProvider = Provider<BackgroundImageStore>(
  (ref) => createBackgroundImageStore(),
);
