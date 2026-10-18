// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picks the global hotkey source for the OS this `dart:io` build runs on.
library;

import 'dart:io' show Platform;

import 'global_hotkeys.dart';
import 'global_hotkeys_channel.dart';
import 'global_hotkeys_portal.dart';

/// The platform is a parameter so a test on Linux can take the Windows branch.
///
/// [underTest] keeps a widget test from asking the real desktop for shortcuts.
GlobalHotkeySource? createGlobalHotkeySource({
  bool? linux,
  bool? windows,
  bool? underTest,
}) {
  if (underTest ?? Platform.environment.containsKey('FLUTTER_TEST')) {
    return null;
  }
  if (linux ?? Platform.isLinux) return PortalGlobalHotkeySource();
  if (windows ?? Platform.isWindows) return ChannelGlobalHotkeySource();
  return null;
}
