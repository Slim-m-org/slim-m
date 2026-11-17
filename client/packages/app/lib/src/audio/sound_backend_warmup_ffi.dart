// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On Linux, initializes GStreamer and loads the elements a cue plays through
/// on a background isolate.
///
/// The first `AudioPlayer` otherwise does it on the GTK main thread, which is
/// also the Dart UI thread: up to 1.4 s on a cold plugin registry, frozen. Later
/// `gst_init` calls return at once. Nothing here opens a sound device.
library;

import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart' show isLinuxHost;

typedef _Ptr = ffi.Pointer<ffi.Void>;

/// What a cue's pipeline is built from: playbin with audioplayers' balance
/// bin, reading a cached wav file out through the sound server.
const _cueElements = [
  'playbin',
  'uridecodebin',
  'decodebin',
  'filesrc',
  'wavparse',
  'audioconvert',
  'audioresample',
  'volume',
  'audiopanorama',
  'autoaudiosink',
  'pulsesink',
  'pipewiresink',
];

Future<void> warmSoundBackend() async {
  if (!isLinuxHost) return;
  try {
    await Isolate.run(_warmGStreamer);
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'Could not ready the sound backend',
      error,
      stack,
    );
  }
}

void _warmGStreamer() {
  final gst = ffi.DynamicLibrary.open('libgstreamer-1.0.so.0');
  final glib = ffi.DynamicLibrary.open('libglib-2.0.so.0');
  final initCheck = gst
      .lookupFunction<
        ffi.Int32 Function(_Ptr, _Ptr, _Ptr),
        int Function(_Ptr, _Ptr, _Ptr)
      >('gst_init_check');
  if (initCheck(ffi.nullptr, ffi.nullptr, ffi.nullptr) == 0) return;
  final find = gst.lookupFunction<_Ptr Function(_Ptr), _Ptr Function(_Ptr)>(
    'gst_element_factory_find',
  );
  final load = gst.lookupFunction<_Ptr Function(_Ptr), _Ptr Function(_Ptr)>(
    'gst_plugin_feature_load',
  );
  final unref = gst
      .lookupFunction<ffi.Void Function(_Ptr), void Function(_Ptr)>(
        'gst_object_unref',
      );
  final malloc = glib
      .lookupFunction<_Ptr Function(ffi.Size), _Ptr Function(int)>('g_malloc0');
  final free = glib
      .lookupFunction<ffi.Void Function(_Ptr), void Function(_Ptr)>('g_free');
  for (final name in _cueElements) {
    final cName = malloc(name.length + 1);
    final bytes = cName.cast<ffi.Uint8>();
    for (var i = 0; i < name.length; i++) {
      bytes[i] = name.codeUnitAt(i);
    }
    final factory = find(cName);
    free(cName);
    if (factory == ffi.nullptr) continue;
    final loaded = load(factory);
    if (loaded != ffi.nullptr) unref(loaded);
    unref(factory);
  }
}
