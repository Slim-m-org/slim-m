// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The WebRTC audio engine's playout and recording state, as words for the
/// call's diagnostics. livekit only reports it on iOS and macOS.
///
/// The engine state API is marked experimental; livekit_client is pinned to
/// an exact version in this package, so a change to it surfaces at the bump.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

// ignore_for_file: experimental_member_use

String engineLine(lk.AudioEngineState state) =>
    'engine playout ${_onOff(state.isPlayoutEnabled)}, '
    'recording ${_onOff(state.isRecordingEnabled)}';

/// The engine right now, or null where livekit reports no engine state.
String? currentEngineLine({bool? apple}) => (apple ?? lk.lkPlatformIsApple())
    ? engineLine(lk.AudioManager.instance.audioEngineState)
    : null;

/// Every engine change as a timeline line, or null where none is reported.
Stream<String>? engineChangeLines({bool? apple}) =>
    (apple ?? lk.lkPlatformIsApple())
        ? lk.AudioManager.instance.audioEngineStateStream
            .map((state) => 'Audio ${engineLine(state)}')
        : null;

String _onOff(bool on) => on ? 'on' : 'off';
