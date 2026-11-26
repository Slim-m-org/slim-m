// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Android system photo picker, the one gallery both composer entries open.
///
/// `file_picker`'s media filter lands in the Documents browser on Android
/// (opening in Downloads, not the camera roll), and a photo strip read through
/// `photo_manager` showed a third, differently sorted list. `image_picker`
/// launches the real photo picker, which lists the newest photos first and
/// needs no media permission.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

export 'picked_copies_none.dart' if (dart.library.io) 'picked_copies_io.dart';

/// Whether this host has it; a provider so tests can pick a platform.
final systemPhotoPickerAvailableProvider = Provider<bool>(
  (ref) => hasSystemPhotoPicker(),
);

/// Opens the photo picker and answers the chosen files, empty if cancelled.
typedef SystemPhotoPicker =
    Future<List<PlatformFile>> Function({
      required bool videos,
      required bool multiple,
    });

/// Only Android has this picker; iOS keeps `PHPicker` through `file_picker`.
bool hasSystemPhotoPicker() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<List<PlatformFile>> _pickFromSystem(
  PickedCopyLog log, {
  required bool videos,
  required bool multiple,
}) async {
  final platform = ImagePickerPlatform.instance;
  // Off by default, which opens the Documents browser instead of the photo picker.
  if (platform is ImagePickerAndroid) platform.useAndroidPhotoPicker = true;
  final picker = ImagePicker();
  final files = switch ((multiple, videos)) {
    (true, true) => await picker.pickMultipleMedia(requestFullMetadata: false),
    (true, false) => await picker.pickMultiImage(requestFullMetadata: false),
    (false, true) => [?await picker.pickMedia(requestFullMetadata: false)],
    (false, false) => [
      ?await picker.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      ),
    ],
  };
  log.record(files.map((f) => f.path));
  return [for (final f in files) _PickedXFile(f)];
}

/// Injectable because `image_picker` has no implementation under test.
final systemPhotoPickerProvider = Provider<SystemPhotoPicker>((ref) {
  final log = ref.watch(pickedCopyLogProvider);
  return ({required bool videos, required bool multiple}) =>
      _pickFromSystem(log, videos: videos, multiple: multiple);
});

/// The paths the photo picker copied, so they can be deleted once unread.
class PickedCopyLog {
  final Set<String> _paths = {};

  void record(Iterable<String> paths) => _paths.addAll(paths);

  /// Hands over every recorded path and forgets them.
  List<String> drain() {
    final taken = _paths.toList();
    _paths.clear();
    return taken;
  }
}

final pickedCopyLogProvider = Provider<PickedCopyLog>((ref) => PickedCopyLog());

final class _PickedXFile extends PlatformFile {
  _PickedXFile(this._file);

  final XFile _file;

  @override
  String get name => _file.name;

  @override
  Uri get uri => Uri.file(_file.path);

  @override
  XFile get xFile => _file;

  @override
  int? lengthSync() => null;

  @override
  Future<int?> length() => _file.length();

  @override
  Future<Uint8List> readAsBytes() => _file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() => _file.openRead();
}
