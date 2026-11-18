// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A modal laid out as a fixed header, a scrolling body and, while an editor
/// in the body holds unsaved edits, a Save footer docked to its bottom edge.
library;

import 'package:flutter/material.dart';

import 'settings_save_bar.dart';

/// What a Save bar shows and does.
typedef PendingSave = ({
  int changeCount,
  bool saving,
  VoidCallback onDiscard,
  VoidCallback onSave,
});

typedef _Published = ({Object owner, PendingSave save});

class SaveFooterScope extends StatefulWidget {
  const SaveFooterScope({super.key, required this.header, required this.body});

  final Widget header;
  final Widget body;

  @override
  State<SaveFooterScope> createState() => _SaveFooterScopeState();
}

class _SaveFooterScopeState extends State<SaveFooterScope> {
  final _pending = ValueNotifier<_Published?>(null);

  @override
  void dispose() {
    _pending.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SaveFooterSlot(
    scope: this,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.header,
        Flexible(child: SingleChildScrollView(child: widget.body)),
        ValueListenableBuilder(
          valueListenable: _pending,
          builder: (context, published, _) => switch (published?.save) {
            null => const SizedBox.shrink(),
            final save => SettingsSaveBar(
              docked: true,
              changeCount: save.changeCount,
              saving: save.saving,
              onDiscard: save.onDiscard,
              onSave: save.onSave,
            ),
          },
        ),
      ],
    ),
  );
}

class _SaveFooterSlot extends InheritedWidget {
  const _SaveFooterSlot({required this.scope, required super.child});

  final _SaveFooterScopeState scope;

  @override
  bool updateShouldNotify(_SaveFooterSlot oldWidget) =>
      scope != oldWidget.scope;
}

/// An editor's Save: docked in the enclosing [SaveFooterScope]'s footer, or
/// [inline] where the editor sits when there is no such modal around it.
class SaveFooterSlot extends StatefulWidget {
  const SaveFooterSlot({super.key, required this.save, required this.inline});

  /// Null while nothing is unsaved.
  final PendingSave? save;
  final WidgetBuilder inline;

  @override
  State<SaveFooterSlot> createState() => _SaveFooterSlotState();
}

class _SaveFooterSlotState extends State<SaveFooterSlot> {
  _SaveFooterScopeState? _footer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _footer = context
        .dependOnInheritedWidgetOfExactType<_SaveFooterSlot>()
        ?.scope;
  }

  @override
  void dispose() {
    _publish(null);
    super.dispose();
  }

  /// After the frame: the footer is built beside this editor, and may already be laid out.
  void _publish(PendingSave? save) {
    final footer = _footer;
    if (footer == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = footer._pending;
      if (!footer.mounted) return;
      if (save == null && pending.value?.owner != this) return;
      pending.value = save == null ? null : (owner: this, save: save);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_footer == null) {
      return widget.save == null
          ? const SizedBox.shrink()
          : widget.inline(context);
    }
    _publish(widget.save);
    return const SizedBox.shrink();
  }
}
