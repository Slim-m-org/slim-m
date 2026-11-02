// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

class _Probe extends ConnectivityPlatform {
  _Probe(this.check);
  final Future<List<ConnectivityResult>> Function() check;
  final changes = StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() => check();

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => changes.stream;
}

const _short = Duration(milliseconds: 50);

void main() {
  test('a probe that throws reads as online', () async {
    final guarded = GuardedConnectivity(
      _Probe(() async => throw StateError('no NetworkManager')),
      timeout: _short,
    );
    expect(await guarded.checkConnectivity(), [ConnectivityResult.other]);
  });

  test('a probe that never answers reads as online after the timeout',
      () async {
    final guarded = GuardedConnectivity(
      _Probe(() => Completer<List<ConnectivityResult>>().future),
      timeout: _short,
    );
    expect(await guarded.checkConnectivity(), [ConnectivityResult.other]);
  });

  test('an uncaught zone error from the probe does not escape', () async {
    final guarded = GuardedConnectivity(
      _Probe(() {
        Future<void>.error(StateError('socket gone'));
        return Completer<List<ConnectivityResult>>().future;
      }),
      timeout: _short,
    );
    expect(await guarded.checkConnectivity(), [ConnectivityResult.other]);
  });

  test('a real answer passes through, including offline', () async {
    final guarded = GuardedConnectivity(
      _Probe(() async => [ConnectivityResult.none]),
      timeout: _short,
    );
    expect(await guarded.checkConnectivity(), [ConnectivityResult.none]);
  });

  test('a degraded probe stops listening to the broken source', () async {
    final probe = _Probe(() async => throw StateError('no bus'));
    final guarded = GuardedConnectivity(probe, timeout: _short);
    await guarded.checkConnectivity();
    expect(await guarded.onConnectivityChanged.isEmpty, isTrue);
    expect(probe.changes.hasListener, isFalse);
  });

  test('a healthy probe forwards its changes', () async {
    final probe = _Probe(() async => [ConnectivityResult.wifi]);
    final guarded = GuardedConnectivity(probe, timeout: _short);
    await guarded.checkConnectivity();
    final next = guarded.onConnectivityChanged.first;
    probe.changes.add([ConnectivityResult.none]);
    expect(await next, [ConnectivityResult.none]);
  });
}
