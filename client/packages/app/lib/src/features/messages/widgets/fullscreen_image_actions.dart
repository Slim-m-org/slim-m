// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The viewer header's Share, Copy and Save controls for the image on screen.
///
/// Share exists only where [ImageExporter.canShare]; Save always exists and
/// is the photo library on a phone, a Save as dialog on a desktop and a
/// download in the browser. A failure is handed up through [onFailure] so the
/// viewer can render it as an [AppErrorState]; a success is a toast.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import 'image_actions.dart';
import 'image_export.dart';

class ImageExportActions extends ConsumerStatefulWidget {
  const ImageExportActions({
    super.key,
    required this.image,
    required this.loadBytes,
    required this.onFailure,
  });

  final api.Attachment image;

  /// The full-resolution bytes of [image], fetched only when an action runs.
  final Future<Uint8List> Function() loadBytes;

  final ValueChanged<String> onFailure;

  @override
  ConsumerState<ImageExportActions> createState() => _ImageExportActionsState();
}

class _ImageExportActionsState extends ConsumerState<ImageExportActions> {
  bool _busy = false;

  Future<void> _run(
    String verb,
    Future<String?> Function(ImageExporter exporter, Uint8List bytes) action,
  ) async {
    setState(() => _busy = true);
    final name = widget.image.filename;
    String? failure;
    try {
      final bytes = await widget.loadBytes();
      failure = await action(ref.read(imageExporterProvider), bytes);
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.media, 'finish the image action', e, stack);
      failure = describeApiFailure('$verb $name', e);
    } catch (error, stack) {
      api.reportFailure(
        api.LogTag.media,
        'finish the image action',
        error,
        stack,
      );
      failure = 'Could not $verb $name.';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) widget.onFailure(failure);
  }

  Future<void> _share(Rect? origin) => _run('share', (exporter, bytes) async {
    await exporter.share(
      bytes,
      filename: widget.image.filename,
      contentType: widget.image.contentType,
      origin: origin,
    );
    return null;
  });

  Future<void> _save() => _runShared(saveImageToDevice);

  Future<void> _copy() => _runShared(copyImageToClipboard);

  Future<void> _runShared(
    Future<String?> Function(
      WidgetRef ref,
      api.Attachment image,
      Future<Uint8List> Function() loadBytes,
    )
    action,
  ) async {
    setState(() => _busy = true);
    final failure = await action(ref, widget.image, widget.loadBytes);
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) widget.onFailure(failure);
  }

  @override
  Widget build(BuildContext context) {
    final exporter = ref.watch(imageExporterProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (exporter.canShare)
          Builder(
            builder: (context) => AppIconButton(
              icon: AppIcons.share,
              semanticLabel: 'Share image',
              tooltip: 'Share',
              size: AppIconButtonSize.touch,
              touch: true,
              onPressed: _busy ? null : () => _share(_originOf(context)),
            ),
          ),
        AppIconButton(
          icon: AppIcons.copy,
          semanticLabel: 'Copy image',
          tooltip: 'Copy image',
          size: AppIconButtonSize.touch,
          touch: true,
          onPressed: _busy ? null : _copy,
        ),
        AppIconButton(
          icon: AppIcons.download,
          semanticLabel: exporter.savesToLibrary
              ? 'Save image to photos'
              : 'Save image as',
          tooltip: exporter.savesToLibrary ? 'Save to photos' : 'Save as...',
          size: AppIconButtonSize.touch,
          touch: true,
          onPressed: _busy ? null : _save,
        ),
      ],
    );
  }

  /// Anchors the iPad share popover on the button rather than the screen.
  Rect? _originOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}
