// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One HEAD request through WinHTTP. Windows checks the server's chain with
/// its own engine, which downloads a trusted root it has not stored yet; the
/// answer itself is ignored.
library;

import 'dart:ffi';

const _automaticProxy = 4;
const _secure = 0x00800000;
const _timeoutMs = 10000;
const _zeroInit = 0x40;

typedef _OpenC = Pointer<Void> Function(
  Pointer<Uint16>,
  Uint32,
  Pointer<Uint16>,
  Pointer<Uint16>,
  Uint32,
);
typedef _Open = Pointer<Void> Function(
  Pointer<Uint16>,
  int,
  Pointer<Uint16>,
  Pointer<Uint16>,
  int,
);
typedef _ConnectC = Pointer<Void> Function(
    Pointer<Void>, Pointer<Uint16>, Uint16, Uint32);
typedef _Connect = Pointer<Void> Function(
    Pointer<Void>, Pointer<Uint16>, int, int);
typedef _OpenRequestC = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Uint16>,
  Pointer<Uint16>,
  Pointer<Uint16>,
  Pointer<Uint16>,
  Pointer<Pointer<Uint16>>,
  Uint32,
);
typedef _OpenRequest = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Uint16>,
  Pointer<Uint16>,
  Pointer<Uint16>,
  Pointer<Uint16>,
  Pointer<Pointer<Uint16>>,
  int,
);
typedef _SendC = Int32 Function(
  Pointer<Void>,
  Pointer<Uint16>,
  Uint32,
  Pointer<Void>,
  Uint32,
  Uint32,
  IntPtr,
);
typedef _Send = int Function(
  Pointer<Void>,
  Pointer<Uint16>,
  int,
  Pointer<Void>,
  int,
  int,
  int,
);
typedef _ReceiveC = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _Receive = int Function(Pointer<Void>, Pointer<Void>);
typedef _TimeoutsC = Int32 Function(Pointer<Void>, Int32, Int32, Int32, Int32);
typedef _Timeouts = int Function(Pointer<Void>, int, int, int, int);
typedef _CloseC = Int32 Function(Pointer<Void>);
typedef _Close = int Function(Pointer<Void>);

/// Blocks for the whole round trip; run it off the UI isolate.
void winHttpHead(String host, int port) {
  final winhttp = DynamicLibrary.open('winhttp.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final alloc = kernel32.lookupFunction<
      Pointer<Uint16> Function(Uint32, IntPtr),
      Pointer<Uint16> Function(int, int)>('LocalAlloc');
  final free = kernel32.lookupFunction<Pointer<Void> Function(Pointer<Uint16>),
      Pointer<Void> Function(Pointer<Uint16>)>('LocalFree');
  final close = winhttp.lookupFunction<_CloseC, _Close>('WinHttpCloseHandle');
  final strings = <Pointer<Uint16>>[];
  Pointer<Uint16> wide(String text) {
    final units = text.codeUnits;
    final pointer = alloc(_zeroInit, (units.length + 1) * 2);
    if (pointer == nullptr) throw StateError('LocalAlloc failed');
    pointer.asTypedList(units.length).setAll(0, units);
    strings.add(pointer);
    return pointer;
  }

  final handles = <Pointer<Void>>[];
  try {
    final session = winhttp.lookupFunction<_OpenC, _Open>('WinHttpOpen')(
      wide('slim-m'),
      _automaticProxy,
      nullptr,
      nullptr,
      0,
    );
    if (session == nullptr) return;
    handles.add(session);
    winhttp.lookupFunction<_TimeoutsC, _Timeouts>('WinHttpSetTimeouts')(
      session,
      _timeoutMs,
      _timeoutMs,
      _timeoutMs,
      _timeoutMs,
    );
    final connection = winhttp.lookupFunction<_ConnectC, _Connect>(
      'WinHttpConnect',
    )(session, wide(host), port, 0);
    if (connection == nullptr) return;
    handles.add(connection);
    final request = winhttp.lookupFunction<_OpenRequestC, _OpenRequest>(
      'WinHttpOpenRequest',
    )(connection, wide('HEAD'), wide('/'), nullptr, nullptr, nullptr, _secure);
    if (request == nullptr) return;
    handles.add(request);
    final sent = winhttp.lookupFunction<_SendC, _Send>('WinHttpSendRequest')(
      request,
      nullptr,
      0,
      nullptr,
      0,
      0,
      0,
    );
    if (sent == 0) return;
    winhttp.lookupFunction<_ReceiveC, _Receive>('WinHttpReceiveResponse')(
      request,
      nullptr,
    );
  } finally {
    for (final handle in handles.reversed) {
      close(handle);
    }
    strings.forEach(free);
  }
}
