// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser half of `web_file_drop.dart`.
library;

import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart'
    show DropItem, DropItemDirectory, DropItemFile;
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// How much of a file one read holds; the upload takes parts of 16 MiB.
const int kDropReadChunk = 4 * 1024 * 1024;

/// [blob] from [start] to [end] in slices of [kDropReadChunk], so a file of
/// any size is never in memory at once.
Stream<Uint8List> blobChunks(web.Blob blob, [int? start, int? end]) async* {
  final stop = math.min(end ?? blob.size, blob.size);
  var at = start ?? 0;
  while (at < stop) {
    final next = math.min(at + kDropReadChunk, stop);
    final buffer = await blob.slice(at, next).arrayBuffer().toDart;
    yield buffer.toDart.asUint8List();
    at = next;
  }
}

/// A dropped browser file whose bytes are read in slices.
class WebDropFile extends DropItemFile {
  WebDropFile(this.file)
    : super(
        web.URL.createObjectURL(file),
        name: file.name,
        length: file.size,
        mimeType: file.type.isEmpty ? null : file.type,
        lastModified: DateTime.fromMillisecondsSinceEpoch(file.lastModified),
      );

  final web.File file;

  @override
  Stream<Uint8List> openRead([int? start, int? end]) =>
      blobChunks(file, start, end);

  @override
  Future<Uint8List> readAsBytes() async =>
      (await file.arrayBuffer().toDart).toDart.asUint8List();
}

/// The file items of [transfer], as drop items; strings and anything else a
/// drag carries beside them are ignored.
List<DropItem> dropItemsFrom(web.DataTransfer transfer) {
  final items = transfer.items;
  final dropped = <DropItem>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item.kind != 'file') continue;
    final entry = item.webkitGetAsEntry();
    final file = item.getAsFile();
    if (entry != null && entry.isDirectory) {
      dropped.add(
        DropItemDirectory(entry.fullPath, const [], name: entry.name),
      );
    } else if (file != null) {
      dropped.add(WebDropFile(file));
    }
  }
  return dropped;
}

bool _carriesFiles(web.DragEvent event) {
  final types = event.dataTransfer?.types.toDart ?? const <JSString>[];
  return types.any((t) => t.toDart == 'Files');
}

class WebFileDropTarget extends StatefulWidget {
  const WebFileDropTarget({
    super.key,
    required this.enable,
    required this.onEntered,
    required this.onUpdated,
    required this.onExited,
    required this.onDone,
    required this.child,
  });

  final bool enable;
  final ValueChanged<Offset> onEntered;
  final ValueChanged<Offset> onUpdated;
  final VoidCallback onExited;
  final void Function(List<DropItem> files, Offset global, Offset local) onDone;
  final Widget child;

  @override
  State<WebFileDropTarget> createState() => _WebFileDropTargetState();
}

class _WebFileDropTargetState extends State<WebFileDropTarget> {
  late final JSFunction _enter = _onEnter.toJS;
  late final JSFunction _over = _onOver.toJS;
  late final JSFunction _leave = _onLeave.toJS;
  late final JSFunction _drop = _onDrop.toJS;

  @override
  void initState() {
    super.initState();
    _listen(true);
  }

  @override
  void dispose() {
    _listen(false);
    super.dispose();
  }

  void _listen(bool on) {
    final window = web.window;
    // Capturing, so a file drop is taken before the plugin's own handler sees it.
    void toggle(String type, JSFunction handler) => on
        ? window.addEventListener(type, handler, true.toJS)
        : window.removeEventListener(type, handler, true.toJS);
    toggle('dragenter', _enter);
    toggle('dragover', _over);
    toggle('dragleave', _leave);
    toggle('drop', _drop);
  }

  Offset _at(web.DragEvent e) =>
      Offset(e.clientX.toDouble(), e.clientY.toDouble());

  void _onEnter(web.DragEvent e) {
    if (!widget.enable || !_carriesFiles(e)) return;
    e.preventDefault();
    widget.onEntered(_at(e));
  }

  void _onOver(web.DragEvent e) {
    if (!widget.enable || !_carriesFiles(e)) return;
    e.preventDefault();
    widget.onUpdated(_at(e));
  }

  void _onLeave(web.DragEvent e) {
    if (!widget.enable || !_carriesFiles(e) || e.relatedTarget != null) return;
    widget.onExited();
  }

  void _onDrop(web.DragEvent e) {
    final transfer = e.dataTransfer;
    if (!widget.enable || transfer == null || !_carriesFiles(e)) return;
    e.preventDefault();
    e.stopPropagation();
    final files = dropItemsFrom(transfer);
    final global = _at(e);
    if (files.isEmpty) return widget.onExited();
    final box = context.findRenderObject();
    final local = box is RenderBox ? box.globalToLocal(global) : global;
    widget.onDone(files, global, local);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
