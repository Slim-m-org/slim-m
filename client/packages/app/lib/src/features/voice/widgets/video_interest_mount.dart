// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells the call a video tile is on screen for as long as it is mounted.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/video_interest_relay.dart';

class VideoInterestMount extends ConsumerStatefulWidget {
  const VideoInterestMount({
    super.key,
    required this.tileKey,
    required this.child,
  });

  /// The tile's `<kind>:<identity>` key.
  final String tileKey;
  final Widget child;

  @override
  ConsumerState<VideoInterestMount> createState() => _VideoInterestMountState();
}

class _VideoInterestMountState extends ConsumerState<VideoInterestMount> {
  late VideoInterestRelay _relay;
  late VoidCallback _release;

  @override
  void initState() {
    super.initState();
    _relay = ref.read(videoInterestRelayProvider);
    _release = _relay.mount(widget.tileKey);
  }

  @override
  void didUpdateWidget(covariant VideoInterestMount oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tileKey == widget.tileKey) return;
    _release();
    _release = _relay.mount(widget.tileKey);
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
