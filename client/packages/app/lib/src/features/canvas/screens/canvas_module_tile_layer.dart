// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The live content of every module tile in view, laid over the board where the document says each tile is.
///
/// The document holds a module tile as a plain [CanvasObjectKind.tile]
/// rectangle, so selecting, moving, resizing, restacking and deleting it are
/// the canvas's own; this layer only fills the rectangle. Each tile is laid
/// out at its world size and scaled by the camera, so every viewer sees the
/// same scene at the same place whatever their screen. A tile is drawn above
/// the ink, since its scene takes taps.
///
/// The tile's header lets pointers through to the board, which is where the
/// select tool grabs it. While a tile is selected the whole of it does, so
/// its resize handles and a drag anywhere on it reach the board.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../modules/widgets/module_command_output.dart';
import '../providers/canvas_module_tiles.dart';
import 'canvas_module_tile_scope.dart';
import 'canvas_presence_geometry.dart';

/// The header's height in world units: the strip a select drag grabs a tile by.
const double canvasModuleTileHeaderHeight = 32;

class CanvasModuleTileLayer extends StatefulWidget {
  const CanvasModuleTileLayer({super.key, required this.document});

  final CanvasDocument document;

  @override
  State<CanvasModuleTileLayer> createState() => _CanvasModuleTileLayerState();
}

class _CanvasModuleTileLayerState extends State<CanvasModuleTileLayer> {
  List<({String id, Rect rect, String tileKey})> _tiles = const [];
  Camera? _camera;

  @override
  void initState() {
    super.initState();
    _listen(widget.document);
    _tiles = widget.document.visibleTiles;
  }

  @override
  void didUpdateWidget(CanvasModuleTileLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document == widget.document) return;
    _unlisten(oldWidget.document);
    _listen(widget.document);
    _tiles = widget.document.visibleTiles;
  }

  @override
  void dispose() {
    _unlisten(widget.document);
    super.dispose();
  }

  void _listen(CanvasDocument document) {
    document.addListener(_onDocumentChanged);
    document.scene.addListener(_onDocumentChanged);
    document.selectedObjectId.addListener(_onSelectionChanged);
  }

  void _unlisten(CanvasDocument document) {
    document.removeListener(_onDocumentChanged);
    document.scene.removeListener(_onDocumentChanged);
    document.selectedObjectId.removeListener(_onSelectionChanged);
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  /// Rebuilds only when the camera moved or a tile in view moved, appeared or went; ink changes leave the tiles alone.
  void _onDocumentChanged() {
    if (!mounted) return;
    final tiles = widget.document.visibleTiles;
    final camera = widget.document.camera;
    if (camera == _camera && _sameTiles(tiles, _tiles)) return;
    setState(() {
      _tiles = tiles;
      _camera = camera;
    });
  }

  static bool _sameTiles(
    List<({String id, Rect rect, String tileKey})> a,
    List<({String id, Rect rect, String tileKey})> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final channelId = CanvasModuleTileScope.maybeOf(context)?.channelId;
    if (channelId == null || _tiles.isEmpty) return const SizedBox.shrink();
    final camera = widget.document.camera;
    final selected = widget.document.selectedObjectId.value;
    return CanvasBoardClip(
      document: widget.document,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final tile in _tiles)
            if (ModuleTileRef.fromKey(tile.tileKey) case final tileRef?)
              Positioned.fromRect(
                key: ValueKey(tile.id),
                rect: presenceScreenRect(tile.rect, camera),
                child: IgnorePointer(
                  ignoring: selected == tile.id,
                  child: FittedBox(
                    fit: BoxFit.fill,
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: tile.rect.width,
                      height: tile.rect.height,
                      child: _ModuleTile(
                        channelId: channelId,
                        objectId: tile.id,
                        tile: tileRef,
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// One tile: a header naming it, then the module's shared scene or why it cannot show one.
class _ModuleTile extends ConsumerStatefulWidget {
  const _ModuleTile({
    required this.channelId,
    required this.objectId,
    required this.tile,
  });

  final String channelId;
  final String objectId;
  final ModuleTileRef tile;

  @override
  ConsumerState<_ModuleTile> createState() => _ModuleTileState();
}

class _ModuleTileState extends ConsumerState<_ModuleTile> {
  CanvasTileFrames get _frames =>
      ref.read(canvasTileFramesProvider(widget.channelId).notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_frames.ensure(widget.objectId));
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final frame = ref.watch(
      canvasTileFramesProvider(
        widget.channelId,
      ).select((frames) => frames[widget.objectId]),
    );
    return Semantics(
      container: true,
      label: '${widget.tile.tile}, a module tile',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border.all(color: tokens.borderSubtle),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              IgnorePointer(child: _header(tokens)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.s8,
                    0,
                    AppSpacing.s8,
                    AppSpacing.s8,
                  ),
                  child: _body(frame),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(AppTokens tokens) => SizedBox(
    height: canvasModuleTileHeaderHeight,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
      child: Row(
        children: [
          Icon(
            AppIcons.dock,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
          const SizedBox(width: AppSpacing.s4),
          Expanded(
            child: Text(
              widget.tile.tile,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.micro.copyWith(color: tokens.textSecondary),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _body(CanvasTileFrame? frame) {
    if (frame?.output case final output?) {
      return ModuleCommandOutput(
        result: api.RunModuleCommandResult(ok: true, output: output),
        moduleId: widget.tile.moduleId,
        command: widget.tile.tile,
        runner: (input) => _frames.press(widget.objectId, input),
        fillAvailable: true,
      );
    }
    if (frame?.error case final error?) {
      return Center(
        child: AppErrorState(
          message: error,
          onRetry: () =>
              unawaited(_frames.ensure(widget.objectId, retry: true)),
        ),
      );
    }
    return const Center(child: AppSpinner(size: AppSpinnerSize.md));
  }
}
