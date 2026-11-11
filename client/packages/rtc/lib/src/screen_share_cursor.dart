// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this machine's mouse cursor is drawn into a screen share it starts.
library;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// The user's choice; [applyShareCursor] hands it to the capturer.
final shareCursorVisible = ValueNotifier<bool>(true);

/// Games hide the cursor in ways the capturer cannot see, so a viewer would watch a cursor the sharer cannot; this is the way out.
/// Read when a capture starts, so it reaches the next share, not a running one.
void applyShareCursor() =>
    rtc.Helper.setScreenCaptureCursor(shareCursorVisible.value);
