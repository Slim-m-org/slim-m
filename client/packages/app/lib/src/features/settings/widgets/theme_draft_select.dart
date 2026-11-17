// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Rebuilds a part of the theme editor only when what it shows of the draft
/// changes, not on every colour a picker drag passes through.
library;

import 'package:flutter/widgets.dart';

import '../providers/theme_draft.dart';

class ThemeDraftSelect<T> extends StatefulWidget {
  const ThemeDraftSelect({
    super.key,
    required this.draft,
    required this.select,
    required this.builder,
  });

  final ThemeDraft draft;

  /// What [builder] reads of the draft, compared with `==` after each change.
  final T Function(ThemeDraft draft) select;
  final Widget Function(BuildContext context, T selected) builder;

  @override
  State<ThemeDraftSelect<T>> createState() => _ThemeDraftSelectState<T>();
}

class _ThemeDraftSelectState<T> extends State<ThemeDraftSelect<T>> {
  late T _selected = widget.select(widget.draft);

  @override
  void initState() {
    super.initState();
    widget.draft.addListener(_changed);
  }

  @override
  void didUpdateWidget(ThemeDraftSelect<T> old) {
    super.didUpdateWidget(old);
    if (old.draft != widget.draft) {
      old.draft.removeListener(_changed);
      widget.draft.addListener(_changed);
    }
    _selected = widget.select(widget.draft);
  }

  @override
  void dispose() {
    widget.draft.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final next = widget.select(widget.draft);
    if (next != _selected) setState(() => _selected = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _selected);
}
