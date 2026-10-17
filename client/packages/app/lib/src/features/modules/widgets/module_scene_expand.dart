// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The control that opens a scene full screen, and gets focus back after.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SceneExpandButton extends StatefulWidget {
  const SceneExpandButton({super.key, required this.onExpand});

  final FutureOr<void> Function() onExpand;

  @override
  State<SceneExpandButton> createState() => _SceneExpandButtonState();
}

class _SceneExpandButtonState extends State<SceneExpandButton> {
  final _focus = FocusNode(debugLabel: 'scene expand');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// A keyboard user leaving full screen lands where they left, not at the top.
  Future<void> _open() async {
    await widget.onExpand();
    if (mounted) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: AppIcons.expand,
    semanticLabel: 'Open full screen',
    tooltip: 'Open full screen',
    focusNode: _focus,
    onPressed: _open,
  );
}
