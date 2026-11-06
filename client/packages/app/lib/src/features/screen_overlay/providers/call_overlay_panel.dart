// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the call panel lists and how it is dressed; the runner only paints it
/// (decision 0096).
library;

import 'package:slimm_design_system/design_system.dart' show AppTokens;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceParticipant;

/// Rows shown before the rest collapse into "+N more".
const callOverlayMaxRows = 8;

/// The call as panel rows: you first, then everyone else in call order so a row does not jump when someone speaks.
({List<OverlayPanelRow> rows, int more}) callOverlayRows(
  List<VoiceParticipant> participants,
) {
  final ordered = [
    ...participants.where((p) => p.isLocal),
    ...participants.where((p) => !p.isLocal),
  ];
  return (
    rows: [
      for (final p in ordered.take(callOverlayMaxRows))
        OverlayPanelRow(
          name: p.isLocal ? '${p.name} (you)' : p.name,
          speaking: p.isSpeaking && !p.isMuted && !p.isDeafened,
          muted: p.isMuted,
          deafened: p.isDeafened,
        ),
    ],
    more: ordered.length > callOverlayMaxRows
        ? ordered.length - callOverlayMaxRows
        : 0,
  );
}

/// The panel for [participants], always in the dark tokens so it reads over any background.
OverlayPanel callOverlayPanel(
  List<VoiceParticipant> participants, {
  required int monitor,
  required OverlayCorner corner,
}) {
  const tokens = AppTokens.dark;
  final (:rows, :more) = callOverlayRows(participants);
  return OverlayPanel(
    monitor: monitor,
    corner: corner,
    rows: rows,
    more: more,
    surface: tokens.surfaceRaised.withValues(alpha: 0.88),
    border: tokens.borderSubtle,
    text: tokens.textPrimary,
    textMuted: tokens.textSecondary,
    accent: tokens.accent,
    danger: tokens.dangerText,
  );
}

/// A screen named by its place and size, which survive a reorder that would shift its index.
String overlayScreenKey(OverlayMonitor m) =>
    '${m.x},${m.y},${m.width},${m.height}';

/// The index of the screen [key] names, or null when it is not plugged in.
int? overlayScreenIndex(OverlaySupport support, String? key) {
  if (key == null) return null;
  final at = support.monitors.indexWhere((m) => overlayScreenKey(m) == key);
  return at < 0 ? null : at;
}

/// The monitor the panel goes on: the chosen screen, else where the app window is, else the primary, else the first.
int callOverlayMonitor(
  OverlaySupport support,
  int? appMonitor, {
  String? chosen,
}) {
  final picked = overlayScreenIndex(support, chosen);
  if (picked != null) return picked;
  final count = support.monitors.length;
  if (appMonitor != null && appMonitor >= 0 && appMonitor < count) {
    return appMonitor;
  }
  final primary = support.monitors.indexWhere((m) => m.primary);
  return primary < 0 ? 0 : primary;
}
