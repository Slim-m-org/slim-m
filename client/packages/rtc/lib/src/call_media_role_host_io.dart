// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real process environment, exported through libc so libpulse sees it.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

Map<String, String> hostEnvironment() => Platform.environment;

typedef _SetenvC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);

/// Dart's own `Platform.environment` is a copy, so only libc's setenv reaches libpulse.
bool hostSetenv(String name, String value) {
  if (!Platform.isLinux) return false;
  final setenv =
      DynamicLibrary.process().lookupFunction<_SetenvC, _SetenvDart>('setenv');
  final n = name.toNativeUtf8();
  final v = value.toNativeUtf8();
  try {
    return setenv(n, v, 1) == 0;
  } finally {
    malloc.free(n);
    malloc.free(v);
  }
}
