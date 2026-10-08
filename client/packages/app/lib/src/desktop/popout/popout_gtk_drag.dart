// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Starts a compositor-driven move or resize on an undecorated GTK window.
///
/// The framework's window controller hides its GTK handle behind `windowHandle`
/// and offers no drag call, and an undecorated window has no border to grab, so
/// this calls the same two GTK functions window_manager uses for the main window.
library;

import 'dart:ffi' as ffi;

import '../desktop_window_port.dart' show ResizeEdge;

typedef _Ptr = ffi.Pointer<ffi.Void>;
typedef _IntOut = ffi.Pointer<ffi.Int32>;

class GtkWindowDrag {
  GtkWindowDrag(this._window);

  final _Ptr _window;

  void move() {
    final at = _PointerState.read();
    _beginMove(_window, 1, at.x, at.y, at.time);
  }

  void resize(ResizeEdge edge) {
    final at = _PointerState.read();
    _beginResize(_window, gdkWindowEdge(edge), 1, at.x, at.y, at.time);
  }
}

/// The `GdkWindowEdge` value GTK expects for [edge].
int gdkWindowEdge(ResizeEdge edge) => switch (edge) {
  ResizeEdge.topLeft => 0,
  ResizeEdge.top => 1,
  ResizeEdge.topRight => 2,
  ResizeEdge.left => 3,
  ResizeEdge.right => 4,
  ResizeEdge.bottomLeft => 5,
  ResizeEdge.bottom => 6,
  ResizeEdge.bottomRight => 7,
};

class _PointerState {
  _PointerState(this.x, this.y, this.time);

  final int x;
  final int y;
  final int time;

  static _PointerState read() {
    final device = _seatPointer(_defaultSeat(_defaultDisplay()));
    final out = _gMalloc(ffi.sizeOf<ffi.Int32>() * 2).cast<ffi.Int32>();
    try {
      _devicePosition(device, ffi.nullptr, out, out + 1);
      return _PointerState(out[0], out[1], _monotonicMicros() & 0xFFFFFFFF);
    } finally {
      _gFree(out.cast());
    }
  }
}

final _gtk = ffi.DynamicLibrary.open('libgtk-3.so.0');
final _gdk = ffi.DynamicLibrary.open('libgdk-3.so.0');
final _glib = ffi.DynamicLibrary.open('libglib-2.0.so.0');

final _beginMove = _gtk
    .lookupFunction<
      ffi.Void Function(_Ptr, ffi.Int32, ffi.Int32, ffi.Int32, ffi.Uint32),
      void Function(_Ptr, int, int, int, int)
    >('gtk_window_begin_move_drag');
final _beginResize = _gtk
    .lookupFunction<
      ffi.Void Function(
        _Ptr,
        ffi.Int32,
        ffi.Int32,
        ffi.Int32,
        ffi.Int32,
        ffi.Uint32,
      ),
      void Function(_Ptr, int, int, int, int, int)
    >('gtk_window_begin_resize_drag');
final _defaultDisplay = _gdk.lookupFunction<_Ptr Function(), _Ptr Function()>(
  'gdk_display_get_default',
);
final _defaultSeat = _gdk
    .lookupFunction<_Ptr Function(_Ptr), _Ptr Function(_Ptr)>(
      'gdk_display_get_default_seat',
    );
final _seatPointer = _gdk
    .lookupFunction<_Ptr Function(_Ptr), _Ptr Function(_Ptr)>(
      'gdk_seat_get_pointer',
    );
final _devicePosition = _gdk
    .lookupFunction<
      ffi.Void Function(_Ptr, _Ptr, _IntOut, _IntOut),
      void Function(_Ptr, _Ptr, _IntOut, _IntOut)
    >('gdk_device_get_position');
final _monotonicMicros = _glib
    .lookupFunction<ffi.Int64 Function(), int Function()>(
      'g_get_monotonic_time',
    );
final _gMalloc = _glib
    .lookupFunction<_Ptr Function(ffi.Size), _Ptr Function(int)>('g_malloc');
final _gFree = _glib
    .lookupFunction<ffi.Void Function(_Ptr), void Function(_Ptr)>('g_free');
