// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The no-source answer, used where `dart:io` does not exist (web).
library;

import 'global_hotkeys.dart';

GlobalHotkeySource? createGlobalHotkeySource(
        {bool? linux, bool? windows, bool? underTest}) =>
    null;
