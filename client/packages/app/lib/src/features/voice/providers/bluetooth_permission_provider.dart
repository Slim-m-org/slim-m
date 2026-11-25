// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

/// The Android Bluetooth grant a call asks for before it joins.
final bluetoothPermissionProvider = Provider<BluetoothPermissionChannel>(
  (ref) => BluetoothPermissionChannel(),
);

/// How long a join waits on the grant dialog before it goes ahead without it.
const bluetoothAskLimit = Duration(seconds: 8);

/// Asks for the grant ahead of a join, but never lets the dialog hold the join up.
///
/// A backgrounded app gets no dialog until it returns, by which time the join's token may have expired.
Future<void> askBluetoothBeforeJoin(
  BluetoothPermissionChannel channel, {
  AppLifecycleState? lifecycle,
  Duration limit = bluetoothAskLimit,
}) async {
  if (lifecycle == AppLifecycleState.paused ||
      lifecycle == AppLifecycleState.hidden) {
    return;
  }
  await channel.request().timeout(limit, onTimeout: () => false);
}
