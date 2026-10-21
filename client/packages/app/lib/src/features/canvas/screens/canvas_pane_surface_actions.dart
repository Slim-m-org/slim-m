// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The callbacks the pane's drawing layers invoke.
library;

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_presence_geometry.dart';

/// Immutable bundle of what [CanvasPaneSurface] reports back to the pane.
@immutable
class CanvasPaneSurfaceActions {
  const CanvasPaneSurfaceActions({
    this.onDraftEnded,
    this.onDraftPoint,
    this.onPointerLeft,
    this.onPointerMoved,
    required this.onShapePlace,
    required this.onNotePlace,
    this.onSelectTap,
    this.onEraseCancel,
    this.onSelectCancel,
    required this.onSelectEnd,
    required this.onSelectDrag,
    required this.onSelectStart,
    required this.onEraseEnd,
    required this.onErase,
    required this.onStroke,
    required this.onCommitTile,
    required this.onVideoInterest,
    required this.onBringToFront,
    required this.onSendToBack,
    required this.onDeleteSelected,
    required this.onPasteImageAt,
    this.onEditNote,
    required this.onRecenter,
    required this.onToolChanged,
    required this.onBringIntoBoard,
    this.participantMenuItemsBuilder,
    this.onFocusTile,
    required this.cameraViewFor,
    required this.screenShareViewFor,
  });

  final VoidCallback? onDraftEnded;
  final DraftPointAdded? onDraftPoint;
  final VoidCallback? onPointerLeft;
  final PointerMoved? onPointerMoved;
  final ShapePlaced onShapePlace;
  final ValueChanged<Offset> onNotePlace;
  final void Function(Offset world, PointerDeviceKind kind)? onSelectTap;
  final VoidCallback onSelectEnd;
  final ValueChanged<Offset> onSelectDrag;
  final ValueChanged<Offset> onSelectStart;
  final VoidCallback onEraseEnd;
  final VoidCallback? onEraseCancel;
  final VoidCallback? onSelectCancel;
  final ValueChanged<Offset> onErase;
  final StrokeCommitted onStroke;
  final void Function(String key, Rect rect) onCommitTile;
  final void Function(Set<String>? tileKeys) onVideoInterest;
  final ValueChanged<String> onBringToFront;
  final ValueChanged<String> onSendToBack;
  final ValueChanged<String> onDeleteSelected;

  final ValueChanged<Offset> onPasteImageAt;
  final ValueChanged<String>? onEditNote;
  final VoidCallback onRecenter;
  final ValueChanged<CanvasTool> onToolChanged;
  final VoidCallback onBringIntoBoard;
  final List<Widget> Function(
    BuildContext context,
    VoiceParticipant participant,
    VoidCallback close,
  )?
  participantMenuItemsBuilder;
  final ValueChanged<String?>? onFocusTile;
  final CameraViewBuilder cameraViewFor;
  final ScreenShareViewBuilder screenShareViewFor;
}
