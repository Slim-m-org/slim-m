// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Runs the drawing consent and the overlay window (decision 0096).
/// Consent is live while viewers may draw and a screen or window is shared. The
/// overlay is up on top of that when this desktop can host it and a whole screen
/// is shared; or it shows the call panel (allowed, in a call, not sharing a
/// whole screen). The two window uses are never wanted together.
library;

import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart'
    show
        PortalMonitor,
        VoiceParticipant,
        VoiceSessionState,
        localShareCapturedSize,
        portalSharedMonitor;

import '../../../providers/sync_controller.dart';
import '../../../providers/toasts.dart';
import '../../members/providers/blocks_controller.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/providers/voice_settings_controller.dart';
import 'call_overlay_avatar.dart';
import 'call_overlay_panel.dart';
import 'overlay_draw_queue.dart';
import 'screen_annotation_board.dart';
import 'screen_annotation_consent.dart';
import 'screen_annotation_mapping.dart';
import 'screen_overlay_frame.dart';

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

/// Interval between repaints while a mark is alive.
const overlayFrameInterval = Duration(milliseconds: 33);

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
    _ref.listen(voiceFlagsProvider, (prev, next) {
      if (prev?.channelId == null && next.channelId != null) _reprobe();
      _reconcile();
    });
    _ref.listen(screenOverlaySupportProvider, (_, _) => _reconcile());
    localShareCapturedSize.addListener(_onCapturedSize);
    _ref.listen(voiceParticipantsProvider, (_, _) => _syncPanel());
    _events = _sync.liveEvents.listen(_onEvent);
    _reconcile();
  }

  final Ref _ref;

  // Held from construction: a provider cannot be read while its container is disposing.
  final SyncController _sync;
  final ScreenOverlay _window;
  final DateTime Function() _clock;
  final _board = ScreenAnnotationBoard();
  late final _draws = OverlayDrawQueue(_window);
  StreamSubscription<api.ServerEvent>? _events;
  Timer? _heartbeat;
  Timer? _frames;
  bool _busy = false;
  bool _again = false;
  String? _channelId;
  String? _selfId;
  double? _overlayAspect;
  bool _panelUp = false;
  int _panelMonitor = 0;
  OverlayPanel? _lastPanel;
  final _avatarWatches =
      <OverlayAvatarWho, ProviderSubscription<AsyncValue<OverlayAvatar>>>{};
  // The picture key the runner holds per user id, so a picture crosses the channel once.
  final _avatarsSent = <String, String>{};

  OverlaySupport get _support =>
      _ref.read(screenOverlaySupportProvider).valueOrNull ??
      const OverlaySupport.unsupported();

  bool get _sharingWholeScreen {
    final flags = _ref.read(voiceFlagsProvider);
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
    final flags = _ref.read(voiceFlagsProvider);
    return _ref
            .read(voiceSettingsControllerProvider)
            .screenShareAllowAnnotations &&
        flags.screenSharing &&
        flags.channelId != null;
  }

  bool get _wanted =>
      _support.supported && _consentWanted && _sharingWholeScreen;

  /// Hidden while a whole screen is shared, since Linux cannot keep the panel out of the stream.
  bool get _panelWanted {
    final flags = _ref.read(voiceFlagsProvider);
    return _support.supported &&
        _ref.read(voiceSettingsControllerProvider).callOverlayEnabled &&
        flags.channelId != null &&
        flags.state == VoiceSessionState.connected &&
        !_sharingWholeScreen;
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
        if (!_consentWanted && state.consenting) await _stop();
        if (_consentWanted && !state.consenting) await _begin();
        if (_consentWanted && state.consenting) await _syncOverlay();
        final panel = !state.active && _panelWanted;
        if (panel && !_panelUp) await _startPanel();
        if (!panel && _panelUp) await _stopPanel();
      } while (_again && mounted);
      _syncPanel();
    } finally {
      _busy = false;
    }
  }

  Future<void> _begin() async {
    final flags = _ref.read(voiceFlagsProvider);
    final self = _ref
        .read(voiceParticipantsProvider)
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
      aspect: up ? _overlayAspect : _capturedAspect(),
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
    if (_wanted && !state.active && await _showOverlay() && mounted) {
      state = state.copyWith(active: true, aspect: () => _overlayAspect);
      _sendConsent(allowed: true);
    } else if (!_wanted && state.active) {
      await _hideOverlay();
      if (!mounted) return;
      state = state.copyWith(active: false, aspect: _capturedAspect);
      _sendConsent(allowed: true);
    }
  }

  double? _capturedAspect() {
    final captured = localShareCapturedSize.value;
    if (captured == null || captured.height == 0) return null;
    return captured.width / captured.height;
  }

  void _onCapturedSize() {
    if (!mounted || !state.consenting || state.active) return;
    final aspect = _capturedAspect();
    if (aspect == state.aspect) return;
    state = state.copyWith(aspect: () => aspect);
    _sendConsent(allowed: true);
  }

  Future<bool> _showOverlay() async {
    final monitors = _support.monitors;
    final controller = _ref.read(voiceControllerProvider.notifier);
    final captured = localShareCapturedSize.value;
    final portal = isWindowsHost ? null : await _portalMonitor();
    if (!mounted) return false;
    final candidates = pickSharedMonitors(
      monitors,
      portalOrigin: portal == null ? null : (x: portal.x, y: portal.y),
      screenNumber: isWindowsHost
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
    // Showing replaces any panel window, which is why the panel is forgotten rather than hidden.
    _forgetPanel();
    _draws.reset();
    if (!await _window.show(covered)) return false;
    _overlayAspect = sharedAspect(monitors, covered);
    return mounted;
  }

  Future<PortalMonitor?> _portalMonitor() =>
      _ref.read(portalSharedMonitorProvider)();

  Future<void> _hideOverlay() async {
    _frames?.cancel();
    _frames = null;
    _board.clear();
    _draws.reset();
    await _window.hide();
  }

  Future<void> _startPanel() async {
    final monitor = callOverlayMonitor(
      _support,
      await _window.appMonitor(),
      chosen: _ref.read(voiceSettingsControllerProvider).callOverlayScreen,
    );
    if (!await _window.show([monitor]) || !mounted) return;
    _panelMonitor = monitor;
    _forgetPanel();
    _panelUp = true;
  }

  Future<void> _stopPanel() async {
    _forgetPanel();
    await _window.hide();
  }

  /// A new or closed window holds none of what was sent before, so nothing is assumed sent.
  void _forgetPanel() {
    _panelUp = false;
    _lastPanel = null;
    _avatarsSent.clear();
    for (final watch in _avatarWatches.values) {
      watch.close();
    }
    _avatarWatches.clear();
  }

  /// Sends the panel only when what it says changed, so a speaking flicker that changes no row costs nothing.
  void _syncPanel() {
    if (!_panelUp || !mounted) return;
    final participants = _ref.read(voiceParticipantsProvider);
    final panel = callOverlayPanel(
      participants,
      monitor: _panelMonitor,
      corner: _ref.read(voiceSettingsControllerProvider).callOverlayCorner,
      avatars: _watchAvatars(callOverlayShown(participants)),
    );
    if (panel == _lastPanel) return;
    _lastPanel = panel;
    unawaited(_window.panel(_picturesOnce(panel)));
  }

  /// Follows the shown people's pictures, so one arriving or changing repaints the panel.
  Map<String, OverlayAvatar> _watchAvatars(List<VoiceParticipant> shown) {
    final wanted = {for (final p in shown) (id: p.identity, name: p.name)};
    _avatarWatches.keys
        .where((who) => !wanted.contains(who))
        .toList()
        .forEach((who) => _avatarWatches.remove(who)?.close());
    for (final who in wanted) {
      _avatarWatches.putIfAbsent(
        who,
        () =>
            _ref.listen(callOverlayAvatarProvider(who), (_, _) => _syncPanel()),
      );
    }
    return {
      for (final entry in _avatarWatches.entries)
        if (entry.value.read().valueOrNull case final avatar?)
          entry.key.id: avatar,
    };
  }

  OverlayPanel _picturesOnce(OverlayPanel panel) => panel.withRows([
    for (final row in panel.rows)
      if (row.avatarKey == null || _avatarsSent[row.id] == row.avatarKey)
        row.withoutAvatarBytes()
      else
        _markSent(row),
  ]);

  OverlayPanelRow _markSent(OverlayPanelRow row) {
    _avatarsSent[row.id] = row.avatarKey!;
    return row;
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
    );
  }

  void _onEvent(api.ServerEvent event) {
    if (event is! api.CanvasScreenAnnotation) return;
    final accepted = overlayAccepts(
      event,
      overlayActive: state.active,
      selfId: _selfId,
      callChannelId: _channelId,
    );
    if (!accepted || _ref.read(blocksProvider).contains(event.userId)) return;
    _board.apply(event, _clock());
    _frames ??= Timer.periodic(overlayFrameInterval, (_) => _paint());
  }

  void _paint() {
    final now = _clock();
    final live = _board.liveAt(now);
    _draws.draw(overlayShapesFor(live, now));
    if (live.isEmpty) {
      _frames?.cancel();
      _frames = null;
    }
  }

  @override
  void dispose() {
    localShareCapturedSize.removeListener(_onCapturedSize);
    _heartbeat?.cancel();
    _frames?.cancel();
    unawaited(_events?.cancel());
    _draws.reset();
    if (state.consenting) _sendConsent(allowed: false);
    if (state.active || _panelUp) {
      unawaited(_window.hide());
    }
    _forgetPanel();
    super.dispose();
  }
}

final screenOverlayControllerProvider =
    StateNotifierProvider<ScreenOverlayController, ScreenOverlayState>(
      (ref) => ScreenOverlayController(ref),
    );
