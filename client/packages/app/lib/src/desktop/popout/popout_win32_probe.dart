// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Logs what a Windows pop-out looks like natively and to Flutter a moment
/// after it opens, so a pop-out that stays blank says why in the app's log:
/// whether the engine ever showed it, and whether the view and its frame
/// agree on a size.
library;

// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:ui' show FlutterView;

import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

typedef _IsWindowVisible = int Function(HWND);
typedef _GetRect = int Function(HWND, ffi.Pointer<ffi.Int32>);
typedef _FindWindowEx =
    HWND Function(HWND, HWND, ffi.Pointer<ffi.Uint16>, ffi.Pointer<ffi.Uint16>);

class _User32 {
  _User32() : _library = ffi.DynamicLibrary.open('user32.dll');

  final ffi.DynamicLibrary _library;

  late final isWindowVisible = _library
      .lookupFunction<ffi.Int32 Function(HWND), _IsWindowVisible>(
        'IsWindowVisible',
      );
  late final getClientRect = _library
      .lookupFunction<
        ffi.Int32 Function(HWND, ffi.Pointer<ffi.Int32>),
        _GetRect
      >('GetClientRect');
  late final getWindowRect = _library
      .lookupFunction<
        ffi.Int32 Function(HWND, ffi.Pointer<ffi.Int32>),
        _GetRect
      >('GetWindowRect');
  late final findWindowEx = _library
      .lookupFunction<
        HWND Function(
          HWND,
          HWND,
          ffi.Pointer<ffi.Uint16>,
          ffi.Pointer<ffi.Uint16>,
        ),
        _FindWindowEx
      >('FindWindowExW');
}

/// Logs [label] for the pop-out on [view] at [window], then its state after
/// each of [after].
void probePopOut(
  String label,
  FlutterView view,
  HWND window, {
  List<Duration> after = const [Duration(seconds: 1), Duration(seconds: 4)],
}) {
  _log(
    '$label: view ${view.viewId}, hwnd 0x${window.address.toRadixString(16)}, '
    'phase ${WidgetsBinding.instance.schedulerPhase.name}',
  );
  for (final wait in after) {
    Timer(wait, () => _logState(view, window, wait));
  }
}

void _logState(FlutterView view, HWND window, Duration wait) {
  try {
    final user32 = _User32();
    final owner = WidgetsBinding.instance.windowingOwner as WindowingOwnerWin32;
    final rect = owner.allocator.allocate<ffi.Int32>(16);
    final name = owner.allocator.allocate<ffi.Uint16>(24);
    try {
      final visible = user32.isWindowVisible(window) != 0;
      user32.getClientRect(window, rect);
      final client = '${rect[2] - rect[0]}x${rect[3] - rect[1]}';
      final units = 'FLUTTERVIEW'.codeUnits;
      for (var i = 0; i < units.length; i++) {
        name[i] = units[i];
      }
      name[units.length] = 0;
      final content = user32.findWindowEx(
        window,
        HWND.fromAddress(0),
        name,
        ffi.Pointer<ffi.Uint16>.fromAddress(0),
      );
      var child = 'none';
      if (content.address != 0) {
        user32.getWindowRect(content, rect);
        child =
            '${rect[2] - rect[0]}x${rect[3] - rect[1]}, '
            'visible ${user32.isWindowVisible(content) != 0}';
      }
      final renderViews = RendererBinding.instance.renderViews
          .where((r) => r.flutterView.viewId == view.viewId)
          .map((r) => '${r.size}')
          .toList();
      _log(
        'after ${wait.inMilliseconds}ms: view ${view.viewId} visible '
        '$visible, client $client, content $child, flutter physical '
        '${view.physicalSize} at ${view.devicePixelRatio}, render views '
        '$renderViews',
      );
    } finally {
      owner.allocator.free(rect);
      owner.allocator.free(name);
    }
  } catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'Could not probe the pop-out',
      error,
      stack,
    );
  }
}

void _log(String message) => AppLog.info(LogTag.platform, 'Pop-out $message');
