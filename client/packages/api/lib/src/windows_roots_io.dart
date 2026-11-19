// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Windows half of [RootFetchingHttpOverrides]: let Windows fetch the
/// root a host needs, then trust what its stores hold now.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'logging/app_log.dart';
import 'root_fetching_http_client.dart';
import 'windows_winhttp_io.dart';

/// Routes every dart:io client this isolate builds through
/// [RootFetchingHttpOverrides]. Windows only; elsewhere the OS store is read
/// in full already. Call it before the first connection.
void installWindowsRootFetching() {
  if (!Platform.isWindows) return;
  HttpOverrides.global = RootFetchingHttpOverrides(_addWindowsRoots);
}

Future<bool> _addWindowsRoots(Uri url) async {
  final port = url.hasPort ? url.port : 443;
  final List<Uint8List> stored;
  try {
    stored = await Isolate.run(() {
      winHttpHead(url.host, port);
      return _storedCertificates();
    });
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.net,
      'Windows could not fetch the roots ${url.host} needs',
      error,
      stack,
    );
    return false;
  }
  var added = 0;
  var unreadable = 0;
  for (final der in stored) {
    try {
      SecurityContext.defaultContext.setTrustedCertificatesBytes(_pem(der));
      added++;
    } on TlsException {
      unreadable++;
    }
  }
  AppLog.info(
    LogTag.net,
    'Trusted $added stored roots for ${url.host}; $unreadable unreadable',
  );
  return added > 0;
}

List<int> _pem(Uint8List der) => utf8.encode(
      '-----BEGIN CERTIFICATE-----\n${base64.encode(der)}\n'
      '-----END CERTIFICATE-----\n',
    );

final class _CertContext extends Struct {
  @Uint32()
  external int encodingType;
  external Pointer<Uint8> encoded;
  @Uint32()
  external int encodedLength;
  external Pointer<Void> info;
  external Pointer<Void> store;
}

/// The stores dart:io reads at startup (SecurityContext on Windows), as they
/// are now: ROOT for anchors and CA for intermediates a server leaves out.
List<Uint8List> _storedCertificates() {
  final crypt32 = DynamicLibrary.open('crypt32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final alloc = kernel32.lookupFunction<
      Pointer<Uint16> Function(Uint32, IntPtr),
      Pointer<Uint16> Function(int, int)>('LocalAlloc');
  final free = kernel32.lookupFunction<Pointer<Void> Function(Pointer<Uint16>),
      Pointer<Void> Function(Pointer<Uint16>)>('LocalFree');
  final open = crypt32.lookupFunction<
      Pointer<Void> Function(IntPtr, Pointer<Uint16>),
      Pointer<Void> Function(int, Pointer<Uint16>)>('CertOpenSystemStoreW');
  final next = crypt32.lookupFunction<
      Pointer<_CertContext> Function(Pointer<Void>, Pointer<_CertContext>),
      Pointer<_CertContext> Function(
          Pointer<Void>, Pointer<_CertContext>)>('CertEnumCertificatesInStore');
  final close = crypt32.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)>('CertCloseStore');
  final found = <Uint8List>[];
  for (final name in const ['ROOT', 'CA']) {
    final units = name.codeUnits;
    final wide = alloc(0x40, (units.length + 1) * 2);
    if (wide == nullptr) continue;
    wide.asTypedList(units.length).setAll(0, units);
    final store = open(0, wide);
    free(wide);
    if (store == nullptr) continue;
    var cert = next(store, nullptr);
    while (cert != nullptr) {
      final length = cert.ref.encodedLength;
      found.add(Uint8List.fromList(cert.ref.encoded.asTypedList(length)));
      cert = next(store, cert);
    }
    close(store, 0);
  }
  return found;
}
