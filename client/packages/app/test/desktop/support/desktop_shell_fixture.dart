// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A [DesktopWindowShell] over a fake port, for tests that drive the shell or
/// render the chrome it gates.
library;

import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';

import 'fake_desktop_window_port.dart';

/// The splash counts as long mapped, so a handoff never waits on a real window.
Future<Duration?> longMapped() async => const Duration(days: 1);

/// [active] and [frameless] seed the state a real bring-up would reach.
DesktopWindowShell shellFor(
  DesktopWindowPort? port, {
  DesktopPlatform? chrome,
  bool Function()? position,
  Future<Duration?> Function()? probe,
  bool active = false,
  bool frameless = false,
}) => DesktopWindowShell(
  port: port ?? FakeDesktopWindowPort(),
  chromePlatform: chrome,
  positionSupported: position ?? () => false,
  splashMappedProbe: probe ?? longMapped,
  active: active,
  frameless: frameless,
);
