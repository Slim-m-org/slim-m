// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The seam between the composer's photo strip and the device photo library.
///
/// `photo_manager` is native-only, so the strip talks to this interface and the
/// plugin sits behind a conditional import: web gets no library at all rather
/// than a stub that fails when called.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'photo_library_none.dart'
    if (dart.library.io) 'photo_library_native.dart';

/// How much of the library the OS let the app read.
enum PhotoAccess {
  /// Every photo.
  full,

  /// Only the photos the user picked (iOS 14+, Android 14+).
  limited,

  /// Nothing; the strip falls back to the system picker.
  denied,
}

/// One recent photo; its bytes load on demand.
class RecentPhoto {
  const RecentPhoto(this.id);
  final String id;
}

/// The original of a photo, ready to stage.
typedef PhotoOriginal = ({Uint8List bytes, String name});

abstract interface class PhotoLibrary {
  Future<PhotoAccess> requestAccess();

  Future<List<RecentPhoto>> recent(int count);

  Future<Uint8List?> thumbnail(String id, int pixels);

  Future<PhotoOriginal?> original(String id);

  /// Reopens the OS selection UI so a limited grant can be widened.
  Future<void> manageLimited();
}

/// Null wherever the device has no photo library to read (web, desktop), which
/// is a capability check and never a layout decision.
final photoLibraryProvider = Provider<PhotoLibrary?>(
  (ref) => createPhotoLibrary(),
);
