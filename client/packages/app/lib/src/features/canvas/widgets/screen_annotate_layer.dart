// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A viewer's pen over someone else's shared screen tile.
///
/// Offered only while that sharer allows it (`ScreenAnnotationFeed`). Marks
/// are ephemeral: they go to the sharer, whose overlay shows them on their
/// real screen, and fade here a few seconds later. Nothing is stored.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/sync_controller.dart';
import '../../screen_overlay/providers/screen_annotation_board.dart';
import '../../screen_overlay/providers/screen_annotation_feed.dart';
import '../../screen_overlay/providers/screen_annotation_mapping.dart';
import '../../screen_overlay/providers/screen_annotation_sender.dart';
import '../../voice/providers/voice_flags.dart';
import '../providers/canvas_pen_style.dart';
import 'screen_annotate_painter.dart';
import 'screen_annotate_toolbar.dart';

/// The narrowest tile, in logical pixels, that gets the toolbar.
const screenAnnotateMinTileWidth = 220.0;

/// Longest sticky note, matching the server's cap.
const screenNoteMaxChars = 80;

class ScreenAnnotateLayer extends ConsumerStatefulWidget {
  const ScreenAnnotateLayer({
    super.key,
    required this.sharerId,
    required this.sharerName,
    required this.tileRect,
  });

  final String sharerId;
  final String sharerName;

  /// The tile's rectangle in the board's screen coordinates.
  final Rect tileRect;

  @override
  ConsumerState<ScreenAnnotateLayer> createState() =>
      _ScreenAnnotateLayerState();
}

class _ScreenAnnotateLayerState extends ConsumerState<ScreenAnnotateLayer>
    with SingleTickerProviderStateMixin {
  late final ScreenAnnotationFeed _feed = ref.read(
    screenAnnotationFeedProvider,
  );
  late final Ticker _ticker = createTicker((_) => _frame.value++);
  final _frame = ValueNotifier<int>(0);
  final _noteText = TextEditingController();
  ScreenAnnotateTool? _tool;
  ScreenAnnotationSender? _sender;
  Offset? _shapeStart;
  Offset? _pendingNote;
  double? _aspect;

  @override
  void initState() {
    super.initState();
    _feed.addListener(_onFeed);
    _onFeed();
  }

  @override
  void dispose() {
    _feed.removeListener(_onFeed);
    _ticker.dispose();
    _frame.dispose();
    _noteText.dispose();
    _sender?.dispose();
    super.dispose();
  }

  void _onFeed() {
    if (!mounted) return;
    final live = _feed.marksFor(widget.sharerId).isNotEmpty;
    if (live && !_ticker.isActive) _ticker.start();
    if (!live && _ticker.isActive) _ticker.stop();
    setState(() {});
  }

  Rect _content() => _aspect == null
      ? Offset.zero & widget.tileRect.size
      : fitContent(widget.tileRect.size, _aspect!);

  void _setTool(ScreenAnnotateTool? tool) {
    _sender?.dispose();
    _sender = null;
    setState(() {
      _tool = tool;
      _pendingNote = null;
    });
  }

  ScreenAnnotationSender _newSender() {
    final self = ref
        .read(voiceParticipantsProvider)
        .firstWhere((p) => p.isLocal)
        .identity;
    final pen = ref.read(canvasActivePenStyleProvider);
    return ScreenAnnotationSender(
      channelId: ref.read(voiceFlagsProvider).channelId!,
      sharerId: widget.sharerId,
      selfId: self,
      colorKey: pen?.colorKey ?? canvasDefaultPenColorKey,
      emit: _emit,
    );
  }

  void _emit(api.CanvasScreenAnnotation frame) {
    _feed.applyLocal(frame);
    ref
        .read(syncControllerProvider.notifier)
        .notifyCanvasScreenAnnotation(
          frame.channelId,
          frame.targetUserId,
          frame.kind,
          annotationId: frame.annotationId,
          points: frame.points,
          color: frame.color,
          text: frame.text,
          ended: frame.ended,
        );
  }

  Offset _norm(Offset local) => toNormalised(local, _content());

  void _panStart(DragStartDetails d) {
    final sender = _sender = _newSender();
    if (_tool == ScreenAnnotateTool.pen) {
      sender.beginStroke(_norm(d.localPosition));
    } else if (_tool == ScreenAnnotateTool.ellipse) {
      _shapeStart = _norm(d.localPosition);
    }
  }

  void _panUpdate(DragUpdateDetails d) {
    final now = _norm(d.localPosition);
    if (_tool == ScreenAnnotateTool.pen) {
      _sender?.extendStroke(now);
    } else if (_shapeStart != null) {
      _sender?.dragShape(_shapeStart!, now);
    }
  }

  void _panEnd() {
    if (_tool == ScreenAnnotateTool.pen) _sender?.endStroke();
    if (_tool == ScreenAnnotateTool.ellipse) _sender?.endShape();
    _shapeStart = null;
  }

  void _submitNote() {
    final at = _pendingNote;
    if (at == null) return;
    (_sender = _newSender()).note(_norm(at), _noteText.text);
    _noteText.clear();
    setState(() => _pendingNote = null);
  }

  @override
  Widget build(BuildContext context) {
    final consent = _feed.consentFor(widget.sharerId);
    if (consent?.aspect != null) _aspect = consent!.aspect;
    final marks = _feed.marksFor(widget.sharerId);
    // Still a Positioned: a loose child would shrink the all-positioned Stack this lives in.
    if (consent == null && marks.isEmpty) return const _Nothing();
    if (consent == null && _tool != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _setTool(null);
      });
    }
    final content = _content();
    final showToolbar =
        consent != null && widget.tileRect.width >= screenAnnotateMinTileWidth;
    return Positioned.fromRect(
      rect: widget.tileRect,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          IgnorePointer(
            child: CustomPaint(
              size: Size.infinite,
              painter: ScreenMarksPainter(
                marks: () => _feed.marksFor(widget.sharerId),
                content: content,
                now: () => _feed.now,
                repaint: _frame,
              ),
            ),
          ),
          IgnorePointer(
            child: ValueListenableBuilder<int>(
              valueListenable: _frame,
              builder: (_, _, _) => Stack(children: _notes(content)),
            ),
          ),
          if (_tool != null && consent != null)
            Positioned.fill(child: _catcher()),
          if (_pendingNote != null) _noteField(),
          if (showToolbar)
            Positioned(
              bottom: AppSpacing.s8,
              left: 0,
              right: 0,
              child: Center(
                child: ScreenAnnotateToolbar(
                  sharerName: widget.sharerName,
                  tool: _tool,
                  onChanged: _setTool,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _catcher() => MouseRegion(
    cursor: SystemMouseCursors.precise,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _panStart,
      onPanUpdate: _panUpdate,
      onPanEnd: (_) => _panEnd(),
      onPanCancel: _panEnd,
      onTapUp: _tool == ScreenAnnotateTool.note
          ? (d) => setState(() => _pendingNote = d.localPosition)
          : null,
    ),
  );

  List<Widget> _notes(Rect content) {
    final now = _feed.now;
    return [
      for (final mark in _feed.marksFor(widget.sharerId))
        if (mark.kind == ScreenAnnotationKind.note &&
            mark.points.length == 2 &&
            mark.text != null)
          Positioned(
            left: fromNormalised(
              Offset(mark.points[0], mark.points[1]),
              content,
            ).dx,
            top: fromNormalised(
              Offset(mark.points[0], mark.points[1]),
              content,
            ).dy,
            child: ScreenNoteChip(text: mark.text!, alpha: mark.alphaAt(now)),
          ),
    ];
  }

  Widget _noteField() {
    final at = _pendingNote!;
    const width = 200.0;
    final left = at.dx.clamp(
      0.0,
      (widget.tileRect.width - width).clamp(0.0, double.infinity),
    );
    return Positioned(
      left: left,
      top: at.dy,
      width: width,
      child: Focus(
        onKeyEvent: (_, event) {
          if (event.logicalKey != LogicalKeyboardKey.escape) {
            return KeyEventResult.ignored;
          }
          setState(() => _pendingNote = null);
          return KeyEventResult.handled;
        },
        child: AppInput(
          controller: _noteText,
          autofocus: true,
          maxLength: screenNoteMaxChars,
          placeholder: 'Say something',
          size: AppInputSize.sm,
          semanticLabel: "Note for ${widget.sharerName}'s screen",
          onSubmitted: (_) => _submitNote(),
        ),
      ),
    );
  }
}

class _Nothing extends StatelessWidget {
  const _Nothing();

  @override
  Widget build(BuildContext context) =>
      const Positioned(width: 0, height: 0, child: SizedBox.shrink());
}
