// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Puts the caret, at the end of the text, in the [Composer] below it: on
/// mount for a pane the user opened on purpose (the docked thread), on a
/// thread switch or a repeat ask for the open thread, and whenever
/// [focusRequests] fires (Reply). Never on mount where it would raise a
/// phone's keyboard unasked.
///
/// The node is found in this subtree rather than taken from
/// [composerFocusNodeProvider]: that registry holds whichever composer mounted
/// last, which with a channel composer beside the pane is not always this one.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../channels/providers/threads.dart';

class ComposerAutofocus extends ConsumerStatefulWidget {
  const ComposerAutofocus({
    super.key,
    required this.channelId,
    required this.child,
    this.focusOnMount = true,
    this.focusRequests,
  });

  final String channelId;

  /// False for a composer the user did not ask for by opening something.
  final bool focusOnMount;

  /// Fires once per explicit ask to type here, such as pressing Reply.
  final Listenable? focusRequests;
  final Widget child;

  @override
  ConsumerState<ComposerAutofocus> createState() => _ComposerAutofocusState();
}

class _ComposerAutofocusState extends ConsumerState<ComposerAutofocus> {
  @override
  void initState() {
    super.initState();
    if (widget.focusOnMount) _focusAfterFrame();
    widget.focusRequests?.addListener(_focusAfterFrame);
    ref.listenManual(
      threadComposerFocusRequestProvider,
      (_, _) => _focusComposer(),
    );
  }

  @override
  void didUpdateWidget(ComposerAutofocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusRequests != widget.focusRequests) {
      oldWidget.focusRequests?.removeListener(_focusAfterFrame);
      widget.focusRequests?.addListener(_focusAfterFrame);
    }
    if (widget.focusOnMount && oldWidget.channelId != widget.channelId) {
      _focusAfterFrame();
    }
  }

  @override
  void dispose() {
    widget.focusRequests?.removeListener(_focusAfterFrame);
    super.dispose();
  }

  void _focusAfterFrame() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusComposer());

  void _focusComposer() {
    if (!mounted) return;
    // Behind a modal (settings, a sheet) the caret would blink unseen and take the keystrokes meant for it.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    EditableText? field;
    void visit(Element element) {
      if (field != null) return;
      final widget = element.widget;
      if (widget is EditableText) {
        field = widget;
      } else {
        element.visitChildren(visit);
      }
    }

    (context as Element).visitChildren(visit);
    if (field == null) return;
    final controller = field!.controller;
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    field!.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
