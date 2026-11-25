// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

/// The Android Bluetooth grant a call asks for before it joins.
final bluetoothPermissionProvider = Provider<BluetoothPermissionChannel>(
  (ref) => BluetoothPermissionChannel(),
);
