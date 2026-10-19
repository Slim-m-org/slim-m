// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Enumerating what a desktop will let this app capture.
///
/// On desktop this is not optional and not a nicety. `getDisplayMedia` matches
/// the requested id against a list the native plugin only fills in when
/// `getSources` is called, so asking to share without enumerating first fails
/// with `source not found!` no matter what else is right. That was the whole
/// Fedora screen-share bug.
///
/// A second, narrower Linux/desktop gap lives one layer below this file, in
/// flutter_webrtc 1.6.0's own `common/cpp` plugin, and is not closeable from
/// here. `MediaStreamTrackDispose`/`MediaStreamDispose`
/// (`flutter_media_stream.cc`) only call `StopCapture()` on a capturer found
/// in `video_capturers_`, and `GetDisplayMedia` (`flutter_screen_capture.cc`)
/// never registers its `desktop_capturer` into that map - only the camera
/// path (`getUserMedia`) does, so a screen-share track gets no *explicit,
/// immediate* stop call on disposal the way a camera track does.
///
/// That is not the same as "nothing ever stops it": `webrtc-sdk/libwebrtc`'s
/// own `ScreenCapturerTrackSource::~ScreenCapturerTrackSource()` calls
/// `capturer->Stop()`, and its destructor tears down the underlying platform
/// capturer, once every reference the flutter_webrtc plugin itself holds is
/// dropped - which `VoiceSession` already causes on every call-ending path
/// (unpublish, `trackDispose`, `streamDispose`, all reached from
/// `_teardown`/`_onDisconnected`). Whether that reference-counted path is
/// what is actually failing in practice, versus the platform's own recording
/// indicator lagging the capture stopping, is not something this package can
/// tell apart without a real Linux desktop capture session. A small patch to
/// register the desktop capturer the same way the camera path does, closing
/// the gap explicitly rather than leaning on refcounting alone, is proposed
/// upstream rather than carried as a fork - see
/// docs/research/linux-screen-share-teardown-2026-08-11/ for the reasoning
/// and the patch itself.
library;

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'screen_share.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The seam. The default implementation talks to libwebrtc's desktop
/// capturer; a test supplies its own.
abstract class DesktopSources {
  /// Whether a share on this platform must name a source. False on mobile,
  /// where the OS owns the choice and there is nothing to enumerate.
  bool get required;

  /// Whether presenting several enumerated sources for a person to choose
  /// between is a real choice, worth its own picker.
  ///
  /// False on Linux. `list` still has to run there (see the class doc), but
  /// on a Wayland session the real choice happens in xdg-desktop-portal's
  /// own picker, which negotiates the capture independently of whatever id
  /// this app hands it - asking here too is a second dialog for one choice,
  /// which is what PR #348's own re-entrancy fix left open as an unverified
  /// native-side possibility, and what "still two popups" confirmed. On X11
  /// this branch was never reachable anyway: enumerating has only ever
  /// returned the one merged screen. macOS and Windows have no such native
  /// picker of their own, so this app's sheet stays their only one.
  bool get sourcePickerUseful;

  Future<List<ScreenShareSource>> list();
}

/// The plugin's own method channel; `resetDesktopSources` exists only in a
/// flutter_webrtc carrying docs/research/linux-wayland-share-switch-2026-09-29.
const _webrtcChannel = MethodChannel('FlutterWebRTC.Method');

class WebrtcDesktopSources implements DesktopSources {
  /// [isLinux] exists so a test can drive the Linux branch.
  const WebrtcDesktopSources({bool? isLinux}) : _isLinux = isLinux;

  final bool? _isLinux;

  bool get _linux => _isLinux ?? lk.lkPlatformIs(lk.PlatformType.linux);

  @override
  bool get required => lk.lkPlatformIsDesktop();

  @override
  bool get sourcePickerUseful => !_linux;

  /// flutter_webrtc caches the portal session for the life of the process, so
  /// a share started after the first one would silently reuse its screen.
  /// Best effort: an unpatched plugin has no such method and keeps the cache.
  Future<void> _dropPortalSession() async {
    try {
      await _webrtcChannel.invokeMethod<void>(
        'resetDesktopSources',
      );
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.voice,
          'Could not reset the screen share source list', error, stack);
      return;
    }
  }

  /// Windows are listed too except on Linux; see [ScreenShareSource] for why.
  /// Screens come first, and a window with no title is left out.
  ///
  /// On Wayland the plugin must hold back libwebrtc's own portal session for
  /// this list, or the first share shows the chooser twice
  /// (`scripts/linux-portal-probe/run.sh` counts them).
  @override
  Future<List<ScreenShareSource>> list() async {
    if (!required) return const [];
    if (_linux) await _dropPortalSession();
    final types = [
      webrtc.SourceType.Screen,
      if (!_linux) webrtc.SourceType.Window,
    ];
    final sources = await webrtc.desktopCapturer.getSources(types: types);
    final screens = <ScreenShareSource>[];
    final windows = <ScreenShareSource>[];
    for (final source in sources) {
      if (source.type == webrtc.SourceType.Window) {
        if (source.name.trim().isEmpty) continue;
        windows.add(
          ScreenShareSource(id: source.id, name: source.name, isWindow: true),
        );
      } else {
        screens.add(ScreenShareSource(id: source.id, name: source.name));
      }
    }
    return [...screens, ...windows];
  }
}
