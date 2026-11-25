// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Deletes the copies the system pickers leave in the app's own storage.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'photo_library.dart';

/// Only phones copy a pick into the app's cache; elsewhere the path is the user's own file.
bool get _copiesPicks =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Tracks which staging lists still read a picked file, and clears the
/// picker copies only once none does.
///
/// A resumable upload re-opens its file for as long as it is uploading or
/// can be retried, so a copy is never removed while a holder says so.
class PickerTempFiles {
  PickerTempFiles(this._clear, {this.clearsMidSession = true});

  final Future<void> Function() _clear;

  /// False where the plugin's clear takes the whole temp folder, which other features write to.
  final bool clearsMidSession;
  final Set<Object> _holders = {};

  /// Records whether [owner] still reads a picked file; a release clears when nobody else reads.
  void update(Object owner, {required bool reading}) {
    if (reading) {
      _holders.add(owner);
      return;
    }
    _holders.remove(owner);
    if (clearsMidSession) _clearWhenIdle();
  }

  /// Clears now unless something is still reading, for launch and for refused picks.
  void clearWhenIdle() => _clearWhenIdle();

  void _clearWhenIdle() {
    if (_holders.isNotEmpty) return;
    _clear().catchError((Object error, StackTrace stack) {
      api.reportFailure(api.LogTag.media, 'clear picker copies', error, stack);
    });
  }
}

/// Only Android's clear is limited to the picker's own folder; iOS's empties the shared temp folder.
bool clearsPicksMidSession(TargetPlatform platform) =>
    platform != TargetPlatform.iOS;

/// One per account session, wired to the plugins' own clear calls on a phone.
final pickerTempFilesProvider = Provider<PickerTempFiles>(
  (ref) => PickerTempFiles(() async {
    if (!_copiesPicks) return;
    await FilePicker.clearTemporaryFiles();
    await ref.read(photoLibraryProvider)?.clearCache();
  }, clearsMidSession: clearsPicksMidSession(defaultTargetPlatform)),
);
