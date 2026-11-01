// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Runs the sharer's overlay: it is up only while the person allows it, is
/// sharing a whole screen, and the desktop can host it (decision 0096).
library;

import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show localShareCapturedSize;

import '../../../providers/sync_controller.dart';
import '../../members/providers/blocks_controller.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/providers/voice_settings_controller.dart';
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
  const ScreenOverlayState({this.active = false});

  /// Whether the overlay is on screen, which is also when viewers are told they may draw.
  final bool active;
}

/// Interval between repaints while a mark is alive.
const overlayFrameInterval = Duration(milliseconds: 33);

class ScreenOverlayController extends StateNotifier<ScreenOverlayState> {
  ScreenOverlayController(this._ref, {DateTime Function()? clock})
    : _clock = clock ?? annotationNow,
      super(const ScreenOverlayState()) {
    _ref.listen(voiceSettingsControllerProvider, (_, _) => _reconcile());
    _ref.listen(voiceFlagsProvider, (_, _) => _reconcile());
    _ref.listen(screenOverlaySupportProvider, (_, _) => _reconcile());
    _events = _ref
        .read(syncControllerProvider.notifier)
        .liveEvents
        .listen(_onEvent);
    _reconcile();
  }

  final Ref _ref;
  final DateTime Function() _clock;
  final _board = ScreenAnnotationBoard();
  StreamSubscription<api.ServerEvent>? _events;
  Timer? _heartbeat;
  Timer? _frames;
  bool _busy = false;
  bool _again = false;
  String? _channelId;
  String? _selfId;
  double? _aspect;

  OverlaySupport get _support =>
      _ref.read(screenOverlaySupportProvider).valueOrNull ??
      const OverlaySupport.unsupported();

  bool get _wanted {
    final flags = _ref.read(voiceFlagsProvider);
    final share = _ref
        .read(voiceControllerProvider.notifier)
        .share
        .lastShareSource;
    return _support.supported &&
        _ref
            .read(voiceSettingsControllerProvider)
            .screenShareAllowAnnotations &&
        flags.screenSharing &&
        flags.channelId != null &&
        !(share?.isWindow ?? false);
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
        if (_wanted && !state.active) await _start();
        if (!_wanted && state.active) await _stop();
      } while (_again && mounted);
    } finally {
      _busy = false;
    }
  }

  Future<void> _start() async {
    final flags = _ref.read(voiceFlagsProvider);
    final self = _ref
        .read(voiceParticipantsProvider)
        .where((p) => p.isLocal)
        .firstOrNull;
    if (self == null || flags.channelId == null) return;
    final monitors = _support.monitors;
    final controller = _ref.read(voiceControllerProvider.notifier);
    final captured = localShareCapturedSize.value;
    final index = pickSharedMonitor(
      monitors,
      screenNumber: isWindowsHost
          ? screenNumberFromLabel(controller.share.lastShareSource?.name ?? '')
          : null,
      capturedSize: captured == null
          ? null
          : Size(captured.width.toDouble(), captured.height.toDouble()),
    );
    if (!await _ref.read(screenOverlayProvider).show(index)) return;
    if (!mounted) return;
    _channelId = flags.channelId;
    _selfId = self.identity;
    _aspect = monitors[index].aspect;
    state = const ScreenOverlayState(active: true);
    _sendConsent(allowed: true);
    _heartbeat = Timer.periodic(
      consentHeartbeat,
      (_) => _sendConsent(allowed: true),
    );
  }

  Future<void> _stop() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _frames?.cancel();
    _frames = null;
    _sendConsent(allowed: false);
    _board.clear();
    state = const ScreenOverlayState();
    await _ref.read(screenOverlayProvider).hide();
  }

  void _sendConsent({required bool allowed}) {
    final channel = _channelId;
    final self = _selfId;
    if (channel == null || self == null) return;
    _ref
        .read(syncControllerProvider.notifier)
        .notifyCanvasScreenAnnotation(
          channel,
          self,
          'consent',
          allowed: allowed,
          aspect: allowed ? _aspect : null,
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
    unawaited(
      _ref.read(screenOverlayProvider).draw(overlayShapesFor(live, now)),
    );
    if (live.isEmpty) {
      _frames?.cancel();
      _frames = null;
    }
  }

  /// Turns the setting off from the indicator; the listener then tears the overlay down.
  Future<void> turnOff() => _ref
      .read(voiceSettingsControllerProvider.notifier)
      .setScreenShareAllowAnnotations(false);

  @override
  void dispose() {
    _heartbeat?.cancel();
    _frames?.cancel();
    unawaited(_events?.cancel());
    if (state.active) {
      _sendConsent(allowed: false);
      unawaited(_ref.read(screenOverlayProvider).hide());
    }
    super.dispose();
  }
}

final screenOverlayControllerProvider =
    StateNotifierProvider<ScreenOverlayController, ScreenOverlayState>(
      (ref) => ScreenOverlayController(ref),
    );
