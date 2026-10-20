// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The host side of [SystemIdle]: `GetLastInputInfo` on Windows and
/// CoreGraphics' event-source counter on macOS.
library;

import 'dart:ffi';
import 'dart:io';

import 'system_idle.dart';

SystemIdle? createSystemIdle() {
  try {
    if (Platform.isWindows) return _WindowsIdle();
    if (Platform.isMacOS) return _MacIdle();
  } on Object {
    return null;
  }
  return null;
}

class _WindowsIdle implements SystemIdle {
  _WindowsIdle() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _lastInputInfo = DynamicLibrary.open('user32.dll').lookupFunction<
        Int32 Function(Pointer<Uint32>),
        int Function(Pointer<Uint32>)>('GetLastInputInfo');
    _tickCount = kernel32.lookupFunction<Uint32 Function(), int Function()>(
      'GetTickCount',
    );
    // One LASTINPUTINFO {UINT cbSize; DWORD dwTime;} for the app's lifetime.
    _info = kernel32.lookupFunction<Pointer<Uint32> Function(Uint32, IntPtr),
        Pointer<Uint32> Function(int, int)>('LocalAlloc')(_zeroInit, 8);
    if (_info == nullptr) throw StateError('LocalAlloc failed');
    _info[0] = 8;
  }

  static const _zeroInit = 0x40;

  late final int Function(Pointer<Uint32>) _lastInputInfo;
  late final int Function() _tickCount;
  late final Pointer<Uint32> _info;

  @override
  Duration? idleTime() {
    if (_lastInputInfo(_info) == 0) return null;
    return windowsIdleSince(_tickCount(), _info[1]);
  }
}

/// Both are 32-bit millisecond tick counts that wrap after 49.7 days.
Duration windowsIdleSince(int nowTicks, int lastInputTicks) =>
    Duration(milliseconds: (nowTicks - lastInputTicks) & 0xFFFFFFFF);

class _MacIdle implements SystemIdle {
  _MacIdle()
      : _secondsSince = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
        ).lookupFunction<Double Function(Int32, Uint32),
            double Function(int, int)>(
          'CGEventSourceSecondsSinceLastEventType',
          isLeaf: true,
        );

  static const _combinedSessionState = 0;
  static const _anyInputEvent = 0xFFFFFFFF;

  final double Function(int, int) _secondsSince;

  @override
  Duration? idleTime() {
    final seconds = _secondsSince(_combinedSessionState, _anyInputEvent);
    if (!seconds.isFinite || seconds < 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }
}
