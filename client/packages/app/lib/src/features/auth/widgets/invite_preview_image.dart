// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An invite's icon or banner from a server nobody has vouched for yet.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/bounded_image_decode.dart';
import '../../../providers/providers.dart';

/// The most an invite image may weigh before it is refused unread.
const inviteImageMaxBytes = 2 * 1024 * 1024;

/// The largest canvas an invite image may declare before it is refused undecoded.
const inviteImageMaxPixels = 4096 * 4096;

/// Fetches an image from [server] through the unvouched probe client with
/// [fetch], under [inviteImageMaxBytes], and decodes it no larger than
/// [maxSide]; a sunken fill stands in while it loads and when it cannot show.
class InvitePreviewImage extends ConsumerStatefulWidget {
  const InvitePreviewImage({
    required this.server,
    required this.fetch,
    required this.maxSide,
    super.key,
  });

  final Uri server;
  final Future<Uint8List> Function(api.SlimmApi client, int maxBytes) fetch;
  final int maxSide;

  @override
  ConsumerState<InvitePreviewImage> createState() => _InvitePreviewImageState();
}

class _InvitePreviewImageState extends ConsumerState<InvitePreviewImage> {
  ui.Image? _image;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(probeApiProvider)(widget.server);
    try {
      final bytes = await widget.fetch(client, inviteImageMaxBytes);
      final image = await decodeBoundedImage(
        bytes,
        maxSide: widget.maxSide,
        maxSourcePixels: inviteImageMaxPixels,
      );
      if (_disposed) {
        image.dispose();
        return;
      }
      setState(() => _image = image);
    } catch (error, stack) {
      api.reportFailure(api.LogTag.auth, 'show an invite image', error, stack);
    } finally {
      client.close();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      final tokens = Theme.of(context).extension<AppTokens>()!;
      return ColoredBox(color: tokens.surfaceSunken);
    }
    return RawImage(image: image, fit: BoxFit.cover);
  }
}
