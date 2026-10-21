// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The video of every camera and screen-share tile, painted before [CanvasSurface] so ink, drafts and cursors sit above it (decision 0086).
/// Carries no gesture; [CanvasPresenceManipulableTile] owns every tile's drag, resize, lock and hide.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../voice/widgets/call_roster_motion.dart';
import 'canvas_presence_bubble.dart';
import 'canvas_presence_frame.dart';
import 'canvas_presence_geometry.dart';

/// Identifies this widget's own [IgnorePointer] for a test to assert on
/// directly, rather than guessing at its position among any others a
/// descendant bubble happens to carry.
@visibleForTesting
const canvasPresenceBackdropIgnorePointerKey = Key(
  'canvas_presence_backdrop_ignore_pointer',
);

/// The non-interactive video backdrop for every visible tile. Renders nothing
/// when no tile is up, so a canvas with no feeds pays only for its listeners.
class CanvasPresenceBackdrop extends StatefulWidget {
  const CanvasPresenceBackdrop({
    super.key,
    required this.document,
    required this.participants,
    required this.cameraViewFor,
    required this.screenShareViewFor,
    required this.overrides,
    this.hideSelfCamera = false,
    this.layout = const CanvasPresenceLayout(),
    this.resolver,
    this.focusedKey,
  });

  /// The tile `CanvasFocusedFeed` is showing, which must not be drawn here as well.
  final String? focusedKey;

  /// Shared with `CanvasPresenceLayer` so both resolve the tiles through one
  /// visibility history; a standalone backdrop makes its own.
  final CanvasPresenceFrameResolver? resolver;

  final CanvasDocument document;
  final List<VoiceParticipant> participants;
  final CameraViewBuilder cameraViewFor;
  final ScreenShareViewBuilder screenShareViewFor;
  final CanvasPresenceTileOverrides overrides;
  final bool hideSelfCamera;
  final CanvasPresenceLayout layout;

  @override
  State<CanvasPresenceBackdrop> createState() => _CanvasPresenceBackdropState();
}

class _CanvasPresenceBackdropState extends State<CanvasPresenceBackdrop> {
  late final CanvasPresenceFrameResolver _resolver =
      widget.resolver ?? CanvasPresenceFrameResolver();

  @override
  void initState() {
    super.initState();
    widget.document.addListener(_onDocumentChanged);
    widget.overrides.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant CanvasPresenceBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      oldWidget.document.removeListener(_onDocumentChanged);
      widget.document.addListener(_onDocumentChanged);
    }
    if (oldWidget.overrides != widget.overrides) {
      oldWidget.overrides.removeListener(_onChanged);
      widget.overrides.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.document.removeListener(_onDocumentChanged);
    widget.overrides.removeListener(_onChanged);
    super.dispose();
  }

  final _viewGate = CanvasViewChangeGate();

  void _onDocumentChanged() {
    if (mounted && _viewGate.changed(widget.document)) setState(() {});
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final frame = _resolver.resolve(
      participants: widget.participants,
      document: widget.document,
      overrides: widget.overrides,
      layout: widget.layout,
      hideSelfCamera: widget.hideSelfCamera,
    );
    final byIdentity = frame.byIdentity;
    final onCanvas = frame.onCanvas;
    if (onCanvas.isEmpty) return const SizedBox.shrink();
    final backKeys = frame.visibleIds
        .where((key) => key != widget.focusedKey)
        .toSet();
    if (backKeys.isEmpty) return const SizedBox.shrink();
    final camera = widget.document.camera;
    _contents.removeWhere((key, _) => !backKeys.contains(key));
    final painted = presencePaintOrder(backKeys, widget.overrides.zFor);
    return CanvasBoardClip(
      document: widget.document,
      child: IgnorePointer(
        key: canvasPresenceBackdropIgnorePointerKey,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final key in painted)
              if (_bubble(key, onCanvas[key]!, camera, byIdentity)
                  case final b?)
                b,
          ],
        ),
      ),
    );
  }

  Widget? _bubble(
    String key,
    Rect worldRect,
    Camera camera,
    Map<String, VoiceParticipant> byIdentity,
  ) {
    final isScreen = presenceTileKind(key) == screenTrackKind;
    final identity = presenceTileIdentity(key);
    final participant = byIdentity[identity];
    if (participant == null) return null;
    final screen = presenceScreenRect(worldRect, camera);
    return Positioned(
      key: ValueKey('video:$key'),
      left: screen.left,
      top: screen.top,
      width: screen.width,
      height: screen.height,
      child: _content(key, participant, isScreen),
    );
  }

  /// One content widget per tile, reused until its feed changes: a fresh video widget each build re-sends the stream to the platform.
  final Map<String, ({bool live, Widget widget})> _contents = {};

  Widget _content(String key, VoiceParticipant participant, bool isScreen) {
    final live = isScreen
        ? participant.isScreenSharing
        : participant.isCameraOn;
    final cached = _contents[key];
    if (cached != null && cached.live == live) return cached.widget;
    final identity = participant.identity;
    final built = CallTilePop(
      child: isScreen
          ? CanvasScreenShareBubble(view: widget.screenShareViewFor(identity))
          : CanvasPresenceBubble(cameraView: widget.cameraViewFor(identity)),
    );
    _contents[key] = (live: live, widget: built);
    return built;
  }
}
