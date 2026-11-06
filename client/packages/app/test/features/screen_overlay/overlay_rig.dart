// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A real overlay controller over fakes for the runner, the socket and the call.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_sync.dart';
import '../voice/voice_controller_harness.dart';

class RigSync extends NoopSyncController {
  RigSync(super.ref);

  final events = StreamController<api.ServerEvent>.broadcast();
  final sent = <({String kind, bool allowed, double? aspect, String target})>[];

  @override
  Stream<api.ServerEvent> get liveEvents => events.stream;

  @override
  void notifyCanvasScreenAnnotation(
    String channelId,
    String targetUserId,
    String kind, {
    String? annotationId,
    List<double> points = const [],
    String? color,
    String? text,
    bool ended = false,
    bool allowed = false,
    double? aspect,
  }) => sent.add((
    kind: kind,
    allowed: allowed,
    aspect: aspect,
    target: targetUserId,
  ));
}

class FakeOverlay implements ScreenOverlay {
  final shown = <List<int>>[];
  final draws = <List<OverlayShape>>[];
  final panels = <OverlayPanel?>[];
  int? appMonitorIndex;
  var hides = 0;

  @override
  Future<OverlaySupport> support() async => const OverlaySupport.unsupported();
  @override
  Future<bool> show(List<int> monitors) async {
    shown.add(monitors);
    return true;
  }

  @override
  Future<void> draw(List<OverlayShape> shapes) async => draws.add(shapes);
  @override
  Future<void> hide() async => hides++;
  @override
  Future<void> panel(OverlayPanel? panel) async => panels.add(panel);
  @override
  Future<int?> appMonitor() async => appMonitorIndex;
}

VoiceParticipant rigMe() => const VoiceParticipant(
  identity: 'me',
  name: 'me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: true,
);

final rigSharing = VoiceState(
  channelId: 'call',
  state: VoiceSessionState.connected,
  screenSharing: true,
  participants: [rigMe()],
);

const rigMonitors = [
  OverlayMonitor(x: 0, y: 0, width: 1920, height: 1080, primary: true),
  OverlayMonitor(x: 1920, y: 0, width: 1280, height: 800, primary: false),
];

class OverlayRig {
  OverlayRig({
    bool allow = true,
    bool callOverlay = false,
    OverlayCorner corner = OverlayCorner.topLeft,
    bool supported = true,
    VoiceState? initial,
    ScreenShareSource? source,
    PortalMonitor? portal,
  }) {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.screen_share_allow_annotations': allow,
      'slimm.voice.call_overlay_enabled': callOverlay,
      'slimm.voice.call_overlay_corner': corner.name,
    });
    container = ProviderContainer(
      overrides: [
        screenOverlayProvider.overrideWithValue(overlay),
        portalSharedMonitorProvider.overrideWithValue(() async => portal),
        screenOverlaySupportProvider.overrideWith(
          (ref) async => supported
              ? const OverlaySupport(supported: true, monitors: rigMonitors)
              : const OverlaySupport.unsupported(),
        ),
        voiceControllerProvider.overrideWith(
          (ref) => voice = FixedVoiceController(ref, initial ?? rigSharing),
        ),
        syncControllerProvider.overrideWith((ref) => sync = RigSync(ref)),
      ],
    );
    container.read(voiceSettingsControllerProvider);
    container.read(voiceControllerProvider);
    voice.share.lastShareSource = source;
    container.read(syncControllerProvider);
    container.read(screenOverlayControllerProvider);
  }

  final overlay = FakeOverlay();
  late final ProviderContainer container;
  late final FixedVoiceController voice;
  late final RigSync sync;

  bool get active => container.read(screenOverlayControllerProvider).active;

  void annotate({
    String target = 'me',
    List<double> points = const [0.1, 0.1, 0.5, 0.5],
    bool ended = true,
  }) => sync.events.add(
    api.CanvasScreenAnnotation(
      channelId: 'call',
      userId: 'viewer',
      targetUserId: target,
      kind: 'stroke',
      annotationId: 'a1',
      points: points,
      color: 'blue',
      ended: ended,
      allowed: false,
    ),
  );
}
