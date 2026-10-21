// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tile video backdrop and the tile controls layer mounted the way the
/// pane's surface does, so a test can drive tiles without the whole pane.
library;

import 'package:flutter/material.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_backdrop.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_frame.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_geometry.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class PresenceStack extends StatefulWidget {
  const PresenceStack({
    super.key,
    required this.document,
    required this.participants,
    required this.cameraViewFor,
    required this.screenShareViewFor,
    required this.overrides,
    required this.onCommit,
    this.onVideoInterest,
    this.hideSelfCamera = false,
    this.layout = const CanvasPresenceLayout(),
    this.tool = CanvasTool.pan,
    this.participantMenuItemsBuilder,
    this.focusedKey,
    this.onFocus,
    this.onPointerMoved,
  });

  final CanvasDocument document;
  final List<VoiceParticipant> participants;
  final CameraViewBuilder cameraViewFor;
  final ScreenShareViewBuilder screenShareViewFor;
  final CanvasPresenceTileOverrides overrides;
  final void Function(String key, Rect rect) onCommit;
  final void Function(Set<String>? tileKeys)? onVideoInterest;
  final bool hideSelfCamera;
  final CanvasPresenceLayout layout;
  final CanvasTool tool;
  final List<Widget> Function(
    BuildContext context,
    VoiceParticipant participant,
    VoidCallback close,
  )?
  participantMenuItemsBuilder;
  final String? focusedKey;
  final ValueChanged<String>? onFocus;
  final PointerMoved? onPointerMoved;

  @override
  State<PresenceStack> createState() => _PresenceStackState();
}

class _PresenceStackState extends State<PresenceStack> {
  final _resolver = CanvasPresenceFrameResolver();

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      CanvasPresenceBackdrop(
        document: widget.document,
        participants: widget.participants,
        cameraViewFor: widget.cameraViewFor,
        screenShareViewFor: widget.screenShareViewFor,
        overrides: widget.overrides,
        hideSelfCamera: widget.hideSelfCamera,
        layout: widget.layout,
        resolver: _resolver,
        focusedKey: widget.focusedKey,
      ),
      CanvasPresenceLayer(
        document: widget.document,
        participants: widget.participants,
        overrides: widget.overrides,
        onCommit: widget.onCommit,
        onVideoInterest: widget.onVideoInterest,
        hideSelfCamera: widget.hideSelfCamera,
        layout: widget.layout,
        tool: widget.tool,
        participantMenuItemsBuilder: widget.participantMenuItemsBuilder,
        resolver: _resolver,
        focusedKey: widget.focusedKey,
        onFocus: widget.onFocus,
        onPointerMoved: widget.onPointerMoved,
      ),
    ],
  );
}
