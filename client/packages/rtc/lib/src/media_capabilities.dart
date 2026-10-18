// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What this device can actually do with media, asked at runtime.
///
/// This exists because the answer is not knowable from the platform alone.
/// Linux screen capture in particular depends on the compositor, the portal
/// implementation, and the flutter_webrtc version, and the project's own
/// research notes and the owner's hands-on testing disagreed about whether it
/// works at all. Rather than carry an assumption either way, the client asks
/// and reports what it got.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Whether a capability is available, and if not, what went wrong.
class CapabilityResult {
  const CapabilityResult.available(this.detail)
      : supported = true,
        error = null;

  const CapabilityResult.unavailable(this.error)
      : supported = false,
        detail = '';

  final bool supported;

  /// Something concrete about what was found, for a spike report or a
  /// diagnostics screen: a track count, a source count, and so on.
  final String detail;

  /// The failure as the platform reported it. Kept verbatim rather than
  /// mapped to a friendly string, because the point of asking is to find out
  /// what a given compositor actually says.
  final String? error;

  @override
  String toString() =>
      supported ? 'available ($detail)' : 'unavailable ($error)';
}

/// Probes the media capabilities that voice and screen share need.
///
/// The flutter_webrtc calls live behind [MediaDevicesProbe] so this class is
/// ordinary logic: a test can drive every branch, including the awkward ones
/// like a portal that answers with nothing, without a device or a compositor.
class MediaCapabilities {
  const MediaCapabilities({MediaDevicesProbe probe = const _RealProbe()})
      : _probe = probe;

  final MediaDevicesProbe _probe;

  /// Whether a microphone can be opened. The track is closed again straight
  /// away: this asks a question, it does not start a call.
  Future<CapabilityResult> microphone() async {
    try {
      final tracks = await _probe.countMicrophoneTracks();
      if (tracks == 0) {
        return const CapabilityResult.unavailable(
          'the platform granted a stream with no audio track',
        );
      }
      return CapabilityResult.available('$tracks audio track(s)');
    } catch (e, stack) {
      AppLog.swallowed(LogTag.voice, 'microphone failed, ignored', e, stack);
      return CapabilityResult.unavailable('$e');
    }
  }

  /// Whether a camera can be opened. The track is closed again straight
  /// away, [microphone]'s own reasoning: this asks a question, it does not
  /// start a call.
  Future<CapabilityResult> camera() async {
    try {
      final tracks = await _probe.countCameraTracks();
      if (tracks == 0) {
        return const CapabilityResult.unavailable(
          'the platform granted a stream with no video track',
        );
      }
      return CapabilityResult.available('$tracks video track(s)');
    } catch (e, stack) {
      AppLog.swallowed(LogTag.voice, 'camera failed, ignored', e, stack);
      return CapabilityResult.unavailable('$e');
    }
  }

  /// Whether the desktop capture portal answers with something to capture.
  ///
  /// On Wayland this goes through the xdg-desktop-portal ScreenCast
  /// interface, which is the piece the old flutter_webrtc PipeWire path got
  /// wrong. Zero sources is a real answer rather than an error: somebody who
  /// dismisses the picker lands here too, so the caller has to read the
  /// message instead of assuming anything that did not throw succeeded.
  Future<CapabilityResult> screenCapture() async {
    try {
      final sources = await _probe.countScreenSources();
      if (sources == 0) {
        return const CapabilityResult.unavailable(
          'the portal offered no capturable sources',
        );
      }
      return CapabilityResult.available('$sources source(s)');
    } catch (e, stack) {
      AppLog.swallowed(
          LogTag.voice, 'screen capture failed, ignored', e, stack);
      return CapabilityResult.unavailable('$e');
    }
  }

  /// Every capability at once, for a diagnostics view or a spike run.
  Future<Map<String, CapabilityResult>> probeAll() async => {
        'microphone': await microphone(),
        'camera': await camera(),
        'screen_capture': await screenCapture(),
      };
}

/// The seam onto flutter_webrtc.
///
/// Deliberately returns counts rather than live media objects. The caller only
/// ever asks "is there anything here", and handing back a `MediaStream` would
/// mean every test had to fake one, plus own closing it.
abstract class MediaDevicesProbe {
  /// Opens the default microphone, counts its audio tracks, and closes it.
  Future<int> countMicrophoneTracks();

  /// Opens the default camera, counts its video tracks, and closes it.
  Future<int> countCameraTracks();

  /// Asks the desktop portal how many screens and windows it will offer.
  Future<int> countScreenSources();
}

class _RealProbe implements MediaDevicesProbe {
  const _RealProbe();

  @override
  Future<int> countMicrophoneTracks() async {
    final stream = await navigator.mediaDevices
        .getUserMedia({'audio': true, 'video': false});
    try {
      return stream.getAudioTracks().length;
    } finally {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
  }

  @override
  Future<int> countCameraTracks() async {
    final stream = await navigator.mediaDevices
        .getUserMedia({'audio': false, 'video': true});
    try {
      return stream.getVideoTracks().length;
    } finally {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
  }

  @override
  Future<int> countScreenSources() async {
    // Screens only, never SourceType.Window: enumerating windows segfaults
    // the whole process on Wayland (see WebrtcDesktopSources, which learned
    // this first); this probe had the crash the sibling already avoided.
    final sources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
    );
    return sources.length;
  }
}
