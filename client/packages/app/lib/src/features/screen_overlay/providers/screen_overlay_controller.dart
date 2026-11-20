// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Runs the drawing consent and the overlay window (decision 0096).
/// Consent is live while viewers may draw and a screen or window is shared. The
/// overlay is up on top of that when this desktop can host it and a whole screen
/// is shared; or it shows the call panel (allowed, in a call). On Linux the two
/// share one window and are never wanted together, since the panel would land in
/// the stream; on Windows the panel has its own window, which capture excludes.
library;

import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart'
    show
        PortalMonitor,
        VoiceSessionState,
        localShareCapturedSize,
        portalSharedMonitor;

import '../../../providers/sync_controller.dart';
import '../../../providers/toasts.dart';
import '../../members/providers/blocks_controller.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/providers/voice_settings_controller.dart';
import 'call_overlay_panel.dart';
import 'call_overlay_panel_sync.dart';
import 'overlay_marks.dart';
import 'portal_screen.dart';
import 'screen_annotation_board.dart';
import 'screen_annotation_consent.dart';
import 'screen_annotation_mapping.dart';
import 'screen_annotation_call.dart';
import 'screen_overlay_frame.dart';
import 'stamp_images.dart';

export 'overlay_marks.dart' show overlayFrameInterval;

/// The native overlay behind its seam; a test supplies a fake.
final screenOverlayProvider = Provider<ScreenOverlay>(
  (ref) => const ChannelScreenOverlay(),
);

/// What this desktop can host, asked once; unsupported anywhere but a Linux or Windows desktop.
final screenOverlaySupportProvider = FutureProvider<OverlaySupport>((
  ref,
) async {
  if (!isLinuxHost && !isWindowsHost) return const OverlaySupport.unsupported();
  return ref.watch(screenOverlayProvider).support();
});

/// Whether the setting is worth offering here.
final screenOverlaySupportedProvider = Provider<bool>(
  (ref) =>
      ref.watch(screenOverlaySupportProvider).valueOrNull?.supported ?? false,
);

class ScreenOverlayState {
  const ScreenOverlayState({
    this.active = false,
    this.consenting = false,
    this.aspect,
  });

  /// Whether the overlay window is on the sharer's screen.
  final bool active;

  /// Whether viewers are told they may draw, which also shows their marks on the sharer's own preview.
  final bool consenting;

  /// The shared screen's width over its height, when known.
  final double? aspect;

  ScreenOverlayState copyWith({bool? active, double? Function()? aspect}) =>
      ScreenOverlayState(
        active: active ?? this.active,
        consenting: consenting,
        aspect: aspect == null ? this.aspect : aspect(),
      );
}

/// Whether this host is Windows, where the overlay windows are excluded from capture; a provider so a test can switch it.
final overlayHostIsWindowsProvider = Provider<bool>((ref) => isWindowsHost);

/// Asks the Linux portal which monitor its chooser picked; a provider so a test can answer.
final portalSharedMonitorProvider = Provider<Future<PortalMonitor?> Function()>(
  (ref) => portalSharedMonitor,
);

class ScreenOverlayController extends StateNotifier<ScreenOverlayState> {
  ScreenOverlayController(this._ref, {DateTime Function()? clock})
    : _clock = clock ?? annotationNow,
      _sync = _ref.read(syncControllerProvider.notifier),
      _window = _ref.read(screenOverlayProvider),
      super(const ScreenOverlayState()) {
    _ref.listen(voiceSettingsControllerProvider, (_, _) => _reconcile());
    _ref.listen(voiceFlagsAtOnce, (prev, next) {
      if (prev?.channelId == null && next.channelId != null) _reprobe();
      if (!next.screenSharing) _portalScreen.forget();
      _reconcile();
      _rosterHold.recheck();
    });
    _ref.listen(screenOverlaySupportProvider, (_, _) {
      if (!_refreshingSupport) _reconcile();
    });
    localShareCapturedSize.addListener(_onCapturedSize);
    _ref.listen(voiceParticipantsAtOnce, (_, _) {
      _panel.sync();
      _rosterHold.recheck();
    });
    _events = _sync.liveEvents.listen(_onEvent);
    _displays = _window.displaysChanged.listen((_) => _onDisplaysChanged());
    _reconcile();
  }

  final Ref _ref;

  // Held from construction: a provider cannot be read while its container is disposing.
  final SyncController _sync;
  final ScreenOverlay _window;
  final DateTime Function() _clock;
  late final _marks = OverlayMarks(
    _window,
    clock: _clock,
    stamps: () => _ref.read(stampImageCacheProvider),
  );
  late final _portalScreen = PortalScreen(
    () => _ref.read(portalSharedMonitorProvider)(),
  );
  late final _rosterHold = RosterHold(
    callChannelId: _stillInCall,
    callMembers: _callMembers,
    release: _admit,
  );
  StreamSubscription<api.ServerEvent>? _events;
  StreamSubscription<void>? _displays;
  bool _relayout = false;
  Timer? _heartbeat;
  bool _busy = false;
  bool _again = false;
  // The pass that refreshed support reads the answer itself; rerunning on it would retry a failed show forever.
  bool _refreshingSupport = false;
  String? _channelId;
  String? _selfId;
  double? _overlayAspect;
  int? _followedWindow;
  late final bool _windows = _ref.read(overlayHostIsWindowsProvider);
  late final _panel = CallOverlayPanelSync(
    _ref,
    _window,
    windows: () => _windows,
    mounted: () => mounted,
    support: () => _support,
  );

  OverlaySupport get _support =>
      _ref.read(screenOverlaySupportProvider).valueOrNull ??
      const OverlaySupport.unsupported();

  bool get _sharingWholeScreen {
    final flags = _ref.read(voiceFlagsAtOnce);
    final share = _ref
        .read(voiceControllerProvider.notifier)
        .share
        .lastShareSource;
    return flags.screenSharing &&
        flags.channelId != null &&
        !(share?.isWindow ?? false);
  }

  /// Viewers may draw: the setting is on and something is being shared, a window included.
  bool get _consentWanted {
    final flags = _ref.read(voiceFlagsAtOnce);
    return _ref
            .read(voiceSettingsControllerProvider)
            .screenShareAllowAnnotations &&
        flags.screenSharing &&
        flags.channelId != null;
  }

  /// Windows only: the handle of the shared window, which the runner keeps the overlay on (decision 0117).
  int? get _sharedWindow {
    if (!_windows) return null;
    final source = _ref
        .read(voiceControllerProvider.notifier)
        .share
        .lastShareSource;
    return source == null || !source.isWindow
        ? null
        : windowHandleFromSourceId(source.id);
  }

  bool get _wanted =>
      _support.supported &&
      _consentWanted &&
      (_sharingWholeScreen || _sharedWindow != null);

  /// Hidden while a whole screen is shared on Linux, which cannot keep the panel out of the stream.
  bool get _panelWanted {
    final flags = _ref.read(voiceFlagsAtOnce);
    return _support.supported &&
        _ref.read(voiceSettingsControllerProvider).callOverlayEnabled &&
        flags.channelId != null &&
        flags.state == VoiceSessionState.connected &&
        (_windows || !_sharingWholeScreen);
  }

  /// A probe that ran before the window was up can read unsupported for good, so each join asks again.
  void _reprobe() {
    if (_support.supported) return;
    _ref.invalidate(screenOverlaySupportProvider);
  }

  /// Brings the overlay in line with what is wanted; one pass at a time, rerun if the answer changed meanwhile.
  Future<void> _reconcile() async {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        if (!mounted) return;
        if (_relayout) await _leaveOldLayout();
        if (!_consentWanted && state.consenting) await _stop();
        if (_consentWanted && !state.consenting) await _begin();
        if (_consentWanted && state.consenting) await _syncOverlay();
        final panel = (_windows || !state.active) && _panelWanted;
        if (panel && !_panel.up) await _panel.start();
        if (!panel && _panel.up) await _panel.stop();
      } while (_again && mounted);
      _panel.sync();
    } finally {
      _busy = false;
    }
  }

  void _onDisplaysChanged() {
    _relayout = true;
    unawaited(_reconcile());
  }

  /// Closes what was opened for the old monitor layout, for the passes after it to open again on the new one.
  Future<void> _leaveOldLayout() async {
    _relayout = false;
    if (!_windows && _sharingWholeScreen) {
      await _portalScreen.layoutChanging(_support.monitors);
      if (!mounted) return;
    }
    await _freshSupport();
    if (!mounted) return;
    api.AppLog.info(
      api.LogTag.platform,
      'Monitor layout changed: overlay up=${state.active}, following a window=${_followedWindow != null}, panel up=${_panel.up}',
    );
    // A followed window is moved by the desktop itself, and the runner follows it.
    if (state.active && _followedWindow == null) {
      await _hideOverlay();
      if (!mounted) return;
      state = state.copyWith(active: false, aspect: _capturedAspect);
    }
    if (_panel.up) await _panel.stop();
  }

  Future<void> _begin() async {
    api.AppLog.info(
      api.LogTag.platform,
      'Drawing consent starting: overlay wanted=$_wanted, window=$_sharedWindow, supported=${_support.supported}',
    );
    final flags = _ref.read(voiceFlagsAtOnce);
    final self = _ref
        .read(voiceParticipantsAtOnce)
        .where((p) => p.isLocal)
        .firstOrNull;
    if (self == null || flags.channelId == null) return;
    _channelId = flags.channelId;
    _selfId = self.identity;
    final up = _wanted && await _showOverlay();
    if (!mounted) return;
    state = ScreenOverlayState(
      active: up,
      consenting: true,
      aspect: up ? _overlayAspectNow : _capturedAspect(),
    );
    _ref.read(toastsProvider.notifier).show('Viewers can draw on your screen.');
    _sendConsent(allowed: true);
    _heartbeat = Timer.periodic(
      consentHeartbeat,
      (_) => _sendConsent(allowed: true),
    );
  }

  /// Opens or closes the overlay window while consent stays, as the shared source or the desktop's support changes.
  Future<void> _syncOverlay() async {
    if (state.active && _wanted && _followedWindow != _sharedWindow) {
      await _hideOverlay();
      if (!mounted) return;
      state = state.copyWith(active: false, aspect: _capturedAspect);
    }
    if (_wanted && !state.active && await _showOverlay() && mounted) {
      state = state.copyWith(active: true, aspect: () => _overlayAspectNow);
      _sendConsent(allowed: true);
    } else if (!_wanted && state.active) {
      await _hideOverlay();
      if (!mounted) return;
      state = state.copyWith(active: false, aspect: _capturedAspect);
      _sendConsent(allowed: true);
    }
  }

  /// A followed window changes shape as it is resized, and the captured frame is that window.
  double? get _overlayAspectNow =>
      _followedWindow == null ? _overlayAspect : _capturedAspect();

  double? _capturedAspect() {
    final captured = localShareCapturedSize.value;
    if (captured == null || captured.height == 0) return null;
    return captured.width / captured.height;
  }

  void _onCapturedSize() {
    if (!mounted || !state.consenting) return;
    if (state.active && _followedWindow == null) return;
    final aspect = _capturedAspect();
    if (aspect == state.aspect) return;
    state = state.copyWith(aspect: () => aspect);
    _sendConsent(allowed: true);
  }

  Future<bool> _showOverlay() async {
    final monitors = (await _freshSupport()).monitors;
    if (!mounted) return false;
    final window = _sharedWindow;
    if (window != null) return _showOverWindow(window);
    final controller = _ref.read(voiceControllerProvider.notifier);
    final captured = localShareCapturedSize.value;
    final shared = _windows ? null : await _portalScreen.find(monitors);
    if (!mounted) return false;
    final candidates = pickSharedMonitors(
      monitors,
      portalIndex: shared,
      sourceId: _windows ? controller.share.lastShareSourceId : null,
      screenNumber: _windows
          ? screenNumberFromLabel(controller.share.lastShareSource?.name ?? '')
          : null,
      capturedSize: captured == null
          ? null
          : Size(captured.width.toDouble(), captured.height.toDouble()),
    );
    // When the share cannot say which screen it is, the screen the overlay was pointed at decides.
    final chosen = overlayScreenIndex(
      _support,
      _ref.read(voiceSettingsControllerProvider).callOverlayScreen,
    );
    final covered = preferChosenScreen(candidates, chosen);
    // On Linux showing replaces the panel window, which is why the panel is forgotten rather than hidden.
    if (!_windows) _panel.forget();
    _marks.reset();
    if (!await _window.show(covered)) return false;
    _overlayAspect = sharedAspect(monitors, covered);
    return mounted;
  }

  Future<bool> _showOverWindow(int window) async {
    _marks.reset();
    final shown = await _window.show(const [0], window: window);
    api.AppLog.info(
      api.LogTag.platform,
      shown
          ? 'Drawing overlay follows shared window $window'
          : 'Drawing overlay could not open over shared window $window',
    );
    if (!shown) return false;
    _followedWindow = window;
    return mounted;
  }

  /// Asks the desktop again: a monitor plugged in, woken or resized since the app started would otherwise be covered by the old layout.
  Future<OverlaySupport> _freshSupport() async {
    _refreshingSupport = true;
    _ref.invalidate(screenOverlaySupportProvider);
    try {
      return await _ref.read(screenOverlaySupportProvider.future);
    } on Object catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.platform,
        'Could not read the monitors again; using the last layout',
        error,
        stack,
      );
      return _support;
    } finally {
      _refreshingSupport = false;
    }
  }

  Future<void> _hideOverlay() async {
    _marks.reset();
    _followedWindow = null;
    await _window.hide();
  }

  Future<void> _stop() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _sendConsent(allowed: false);
    final wasActive = state.active;
    state = const ScreenOverlayState();
    if (wasActive) await _hideOverlay();
  }

  void _sendConsent({required bool allowed}) {
    final channel = _channelId;
    final self = _selfId;
    if (channel == null || self == null) return;
    _sync.notifyCanvasScreenAnnotation(
      channel,
      self,
      'consent',
      allowed: allowed,
      aspect: allowed ? state.aspect : null,
      stamps: allowed,
    );
  }

  void _onEvent(api.ServerEvent event) {
    if (event is! api.CanvasScreenAnnotation || event.kind == 'consent') return;
    final mine = state.active && event.targetUserId == _selfId;
    if (!mine || !_rosterHold.holds(event)) _admit(event);
  }

  /// The call my consent went out in, or null once I have left or switched it.
  String? _stillInCall() =>
      _ref.read(voiceFlagsAtOnce).channelId == _channelId ? _channelId : null;

  Iterable<String> _callMembers() =>
      _ref.read(voiceParticipantsAtOnce).map((p) => p.identity);

  void _admit(api.CanvasScreenAnnotation event) {
    final accepted = overlayAccepts(
      event,
      overlayActive: state.active,
      selfId: _selfId,
      callChannelId: _channelId,
      callMembers: _callMembers(),
    );
    if (!accepted || _ref.read(blocksProvider).contains(event.userId)) return;
    _marks.add(event);
  }

  @override
  void dispose() {
    localShareCapturedSize.removeListener(_onCapturedSize);
    _heartbeat?.cancel();
    _rosterHold.dispose();
    unawaited(_events?.cancel());
    unawaited(_displays?.cancel());
    _marks.dispose();
    if (state.consenting) _sendConsent(allowed: false);
    if (state.active || (_panel.up && !_windows)) {
      unawaited(_window.hide());
    }
    if (_panel.up && _windows) unawaited(_window.panel(null));
    _panel.forget();
    super.dispose();
  }
}

final screenOverlayControllerProvider =
    StateNotifierProvider<ScreenOverlayController, ScreenOverlayState>(
      (ref) => ScreenOverlayController(ref),
    );
