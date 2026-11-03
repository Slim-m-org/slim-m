// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'background_image_store.dart';

BackgroundImageStore createBackgroundImageStore() => FileBackgroundImageStore();

/// One file under the application support directory, or under [directory].
class FileBackgroundImageStore implements BackgroundImageStore {
  FileBackgroundImageStore({Directory? directory}) : _directory = directory;

  final Directory? _directory;

  Future<File> _file() async {
    final base = _directory ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'appearance'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, 'background.png'));
  }

  @override
  Future<Uint8List?> read() async {
    try {
      final file = await _file();
      return await file.exists() ? await file.readAsBytes() : null;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'Could not read the background picture',
        error,
        stack,
      );
      return null;
    }
  }

  @override
  Future<bool> write(Uint8List bytes) async {
    try {
      final file = await _file();
      final partial = File('${file.path}.part');
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(file.path);
      return true;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'Could not save the background picture',
        error,
        stack,
      );
      return false;
    }
  }

  @override
  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'Could not remove the background picture',
        error,
        stack,
      );
    }
  }
}
