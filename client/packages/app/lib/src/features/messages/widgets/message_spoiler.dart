// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A `||spoiler||` span: a filled bar that swaps for its text on tap or on
/// Enter/Space once tabbed to - it used to be a bare `GestureDetector`,
/// which Flutter never makes a tab stop, so a spoiler could not be revealed
/// from the keyboard at all.
///
/// The hidden text stays mounted underneath the bar for sizing, which used
/// to mean it stayed selectable too: a `SelectionArea` a level up (the
/// desktop transcript's own `TranscriptSelection`) could select clean past
/// an unrevealed bar and copy the spoiler's real text, opacity 0 or not -
/// `transcript_selection_content_test.dart` is what caught it, by actually
/// selecting and reading the clipboard back rather than only checking a
/// widget was present. `SelectionContainer.disabled` around the hidden text
/// is what a `SelectionArea` reads to mean "not part of this selection",
/// the same job `ExcludeSemantics` already did for a screen reader.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Deliberately this simple rather than an animated reveal: Discord's own
/// affordance for a spoiler is exactly a tap toggle, nothing more.
class MessageSpoiler extends StatefulWidget {
  const MessageSpoiler({super.key, required this.style, required this.spans});

  final TextStyle style;
  final List<InlineSpan> spans;

  @override
  State<MessageSpoiler> createState() => _MessageSpoilerState();
}

class _MessageSpoilerState extends State<MessageSpoiler> {
  bool _revealed = false;
  bool _focused = false;

  void _toggle() => setState(() => _revealed = !_revealed);

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      toggled: _revealed,
      label: _revealed ? null : 'Hidden spoiler',
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => _toggle(),
          ),
        },
        child: GestureDetector(
          onTap: _toggle,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Kept in the tree (sizes the bar) but hidden from assistive tech until shown.
              ExcludeSemantics(
                excluding: !_revealed,
                child: Opacity(
                  opacity: _revealed ? 1 : 0,
                  // Opacity hides pixels, not selectability - see this file's own doc comment.
                  child: _revealed
                      ? Text.rich(
                          TextSpan(style: widget.style, children: widget.spans),
                        )
                      : SelectionContainer.disabled(
                          child: Text.rich(
                            TextSpan(
                              style: widget.style,
                              children: widget.spans,
                            ),
                          ),
                        ),
                ),
              ),
              if (!_revealed)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.textPrimary,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                  ),
                ),
              // Only mounted while focus-highlighted, so a tap-driven run sees no extra DecoratedBox.
              if (_focused)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: tokens.focusRing, width: 2),
                        borderRadius: BorderRadius.circular(AppRadii.control),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
