// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An inline piece of text that opens a link: reachable by Tab, activated by
/// Enter or Space, and announced as a link.
///
/// Built on [FocusableActionDetector] rather than the design system's
/// `FocusableTapTarget`, which floors its hit area at a row's height; a title
/// or author line is inline text whose size is the design.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class TextLink extends StatefulWidget {
  const TextLink({super.key, required this.onOpen, required this.child});

  final VoidCallback onOpen;
  final Widget child;

  @override
  State<TextLink> createState() => _TextLinkState();
}

class _TextLinkState extends State<TextLink> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      link: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onOpen();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onOpen,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: _focused
                  ? Border.all(color: tokens.focusRing, width: 2)
                  : null,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
