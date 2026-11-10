// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the call panel lists and how it is dressed; the runner only paints it
/// (decision 0096).
library;

import 'package:slimm_design_system/design_system.dart' show AppTokens;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceParticipant;

import 'call_overlay_avatar.dart' show OverlayAvatar;

/// Rows shown before the rest collapse into "+N more".
const callOverlayMaxRows = 8;

/// The people the panel lists: you first, then everyone else in call order so a row does not jump when someone speaks.
List<VoiceParticipant> callOverlayShown(List<VoiceParticipant> participants) {
  final ordered = [
    ...participants.where((p) => p.isLocal),
    ...participants.where((p) => !p.isLocal),
  ];
  return ordered.take(callOverlayMaxRows).toList();
}

/// The call as panel rows, each with its baked picture from [avatars] (by user id) when there is one.
({List<OverlayPanelRow> rows, int more}) callOverlayRows(
  List<VoiceParticipant> participants, {
  Map<String, OverlayAvatar> avatars = const {},
}) {
  return (
    rows: [
      for (final p in callOverlayShown(participants))
        OverlayPanelRow(
          id: p.identity,
          name: p.isLocal ? '${p.name} (you)' : p.name,
          speaking: p.isSpeaking && !p.isMuted && !p.isDeafened,
          muted: p.isMuted,
          deafened: p.isDeafened,
          avatarKey: avatars[p.identity]?.key,
          avatar: avatars[p.identity]?.png,
        ),
    ],
    more: participants.length > callOverlayMaxRows
        ? participants.length - callOverlayMaxRows
        : 0,
  );
}

/// How much of the dark surface shows through; faint enough to read the screen behind it.
const callOverlaySurfaceAlpha = 0.6;

/// Name text sits a little under full strength so the panel stays in the background.
const callOverlayTextAlpha = 0.9;

/// The panel for [participants], always in the dark tokens so it reads over any background.
OverlayPanel callOverlayPanel(
  List<VoiceParticipant> participants, {
  required int monitor,
  required OverlayCorner corner,
  Map<String, OverlayAvatar> avatars = const {},
}) {
  const tokens = AppTokens.dark;
  final (:rows, :more) = callOverlayRows(participants, avatars: avatars);
  return OverlayPanel(
    monitor: monitor,
    corner: corner,
    rows: rows,
    more: more,
    surface: tokens.surfaceRaised.withValues(alpha: callOverlaySurfaceAlpha),
    border: tokens.borderSubtle,
    text: tokens.textPrimary.withValues(alpha: callOverlayTextAlpha),
    textMuted: tokens.textSecondary.withValues(alpha: callOverlayTextAlpha),
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
