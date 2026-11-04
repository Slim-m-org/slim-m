// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Cascading submenus for [AppMenu]: a row that opens a second menu beside it
/// on a pointer layout, and swaps the sheet's content for it on a phone.
///
/// Every [AppMenu] is its own level, so a submenu row only ever talks to the
/// menu it sits in, and a submenu may hold submenu rows of its own.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_icons.dart';
import '../../app_motion.dart';
import 'menu.dart';

/// How long the pointer rests on a submenu row before it opens by itself.
const Duration kSubmenuHoverDelay = Duration(milliseconds: 250);

/// Where the panel sits against its row: close enough that the pointer crosses
/// the parent menu's padding straight into it.
const double _panelGap = 4;

/// The parent card's 1px border plus its default 6px padding, so the panel's
/// first row lines up with the row that opened it.
const double _panelInset = 7;

const double _screenMargin = 8;

/// What one level of a menu knows about its submenu: which row has its panel
/// open, and, on a phone, which submenus the sheet has swapped into.
class AppMenuCascadeController extends ChangeNotifier {
  AppMenuCascadeController({required this.swap});

  /// True where the menu is a bottom sheet: a submenu replaces its content
  /// instead of floating beside it.
  final bool swap;

  Object? _open;
  final List<_SwapEntry> _stack = [];

  Object? get open => _open;

  bool isOpen(Object id) => _open == id;

  void openPanel(Object id) {
    if (_open == id) return;
    _open = id;
    notifyListeners();
  }

  void closePanel([Object? id]) {
    if (_open == null || (id != null && _open != id)) return;
    _open = null;
    notifyListeners();
  }

  /// A row going away takes its panel with it and must not notify mid-unmount.
  void forget(Object id) {
    if (_open == id) _open = null;
  }

  void swapTo(String label, List<Widget> Function(BuildContext) builder) {
    _stack.add(_SwapEntry(label, builder));
    notifyListeners();
  }

  void swapBack() {
    if (_stack.isEmpty) return;
    _stack.removeLast();
    notifyListeners();
  }
}

class _SwapEntry {
  const _SwapEntry(this.label, this.builder);

  final String label;
  final List<Widget> Function(BuildContext) builder;
}

class _CascadeScope extends InheritedNotifier<AppMenuCascadeController> {
  const _CascadeScope({
    required AppMenuCascadeController controller,
    required super.child,
  }) : super(notifier: controller);
}

/// One menu level's cascade state, provided to the rows below it.
class AppMenuCascade extends StatefulWidget {
  const AppMenuCascade({super.key, this.swap = false, required this.child});

  /// See [AppMenuCascadeController.swap].
  final bool swap;
  final Widget child;

  /// The nearest level, or null outside any menu. Rows that only need to tell
  /// the level the pointer moved pass `listen: false`.
  static AppMenuCascadeController? maybeOf(
    BuildContext context, {
    bool listen = true,
  }) {
    final scope = listen
        ? context.dependOnInheritedWidgetOfExactType<_CascadeScope>()
        : context.getInheritedWidgetOfExactType<_CascadeScope>();
    return scope?.notifier;
  }

  @override
  State<AppMenuCascade> createState() => _AppMenuCascadeState();
}

class _AppMenuCascadeState extends State<AppMenuCascade> {
  late final _controller = AppMenuCascadeController(swap: widget.swap);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _CascadeScope(
      controller: _controller,
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final top = _controller._stack.lastOrNull;
          if (top == null) return widget.child;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppMenuItem(
                key: const Key('menu-submenu-back'),
                label: top.label,
                leading: AppIcons.back,
                onTap: _controller.swapBack,
              ),
              const AppMenuDivider(),
              ...top.builder(context),
            ],
          );
        },
      ),
    );
  }
}

/// The tap-region group the host menu's outside-tap check uses, so a tap inside
/// a submenu's panel does not count as outside the menu that owns it.
class AppMenuTapGroup extends InheritedWidget {
  const AppMenuTapGroup({
    super.key,
    required this.groupId,
    required super.child,
  });

  final Object groupId;

  static Object? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppMenuTapGroup>()?.groupId;

  @override
  bool updateShouldNotify(AppMenuTapGroup oldWidget) =>
      groupId != oldWidget.groupId;
}

class _OpenIntent extends Intent {
  const _OpenIntent();
}

/// A row that opens a submenu: beside it on a pointer layout, in place of the
/// sheet's content on a phone.
///
/// Choosing a row inside the submenu is the caller's to finish by closing the
/// whole menu, since only the caller holds that menu's close callback.
class AppSubmenuItem extends StatefulWidget {
  const AppSubmenuItem({
    super.key,
    required this.label,
    required this.itemsBuilder,
    this.leading,
    this.trailing,
    this.panelWidth = 240,
    this.semanticLabel,
  });

  final String label;
  final IconData? leading;
  final Widget? trailing;
  final List<Widget> Function(BuildContext context) itemsBuilder;
  final double panelWidth;
  final String? semanticLabel;

  @override
  State<AppSubmenuItem> createState() => _AppSubmenuItemState();
}

class _AppSubmenuItemState extends State<AppSubmenuItem> {
  final _portal = OverlayPortalController();
  Timer? _hoverTimer;
  AppMenuCascadeController? _cascade;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppMenuCascade.maybeOf(context);
    if (identical(next, _cascade)) return;
    _cascade?.removeListener(_sync);
    _cascade = next;
    next?.addListener(_sync);
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _cascade
      ?..removeListener(_sync)
      ..forget(this);
    super.dispose();
  }

  bool get _isOpen => _cascade?.isOpen(this) ?? false;

  void _sync() {
    if (!mounted) return;
    if (_isOpen && !_portal.isShowing) _portal.show();
    if (!_isOpen && _portal.isShowing) _portal.hide();
  }

  void _open() {
    _hoverTimer?.cancel();
    final cascade = _cascade;
    if (cascade == null) return;
    if (cascade.swap) {
      cascade.swapTo(widget.label, widget.itemsBuilder);
    } else {
      cascade.openPanel(this);
    }
  }

  void _scheduleOpen() {
    final cascade = _cascade;
    if (cascade == null || cascade.swap || _isOpen) return;
    _hoverTimer?.cancel();
    _hoverTimer = Timer(kSubmenuHoverDelay, _open);
  }

  Rect? _rowRect(RenderBox overlay) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  }

  Widget _panel(BuildContext overlayContext) {
    final overlay = Overlay.of(context).context.findRenderObject();
    final row = overlay is RenderBox ? _rowRect(overlay) : null;
    if (row == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _PanelLayout(
          row: row,
          padding: MediaQuery.paddingOf(overlayContext) +
              const EdgeInsets.all(_screenMargin),
        ),
        child: _SubmenuPanel(
          width: widget.panelWidth,
          groupId: AppMenuTapGroup.maybeOf(context),
          onClose: () => _cascade?.closePanel(this),
          builder: widget.itemsBuilder,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _panel,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowRight): _OpenIntent(),
        },
        child: Actions(
          actions: {
            _OpenIntent: CallbackAction<_OpenIntent>(
              onInvoke: (_) {
                _open();
                return null;
              },
            ),
          },
          child: AppMenuItem(
            label: widget.label,
            leading: widget.leading,
            trailing: widget.trailing,
            semanticLabel: widget.semanticLabel,
            submenu: true,
            highlighted: _isOpen,
            onPointerEnter: _scheduleOpen,
            onPointerExit: () => _hoverTimer?.cancel(),
            onTap: _open,
          ),
        ),
      ),
    );
  }
}

/// Beside the row, flipped to its left when the right is out of room, and
/// slid up or down to stay inside the window.
class _PanelLayout extends SingleChildLayoutDelegate {
  const _PanelLayout({required this.row, required this.padding});

  final Rect row;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(padding);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final right = row.right + _panelGap;
    final fitsRight = right + childSize.width <= size.width - padding.right;
    final x = fitsRight ? right : row.left - _panelGap - childSize.width;
    final maxY = size.height - padding.bottom - childSize.height;
    return Offset(
      x.clamp(padding.left, size.width),
      (row.top - _panelInset)
          .clamp(padding.top, maxY < padding.top ? padding.top : maxY),
    );
  }

  @override
  bool shouldRelayout(_PanelLayout oldDelegate) =>
      row != oldDelegate.row || padding != oldDelegate.padding;
}

/// The floating card: a fade in, its own focus scope so Escape and Left close
/// only this level, and the group that keeps taps inside it from dismissing
/// the parent.
class _SubmenuPanel extends StatefulWidget {
  const _SubmenuPanel({
    required this.width,
    required this.groupId,
    required this.onClose,
    required this.builder,
  });

  final double width;
  final Object? groupId;
  final VoidCallback onClose;
  final List<Widget> Function(BuildContext) builder;

  @override
  State<_SubmenuPanel> createState() => _SubmenuPanelState();
}

class _SubmenuPanelState extends State<_SubmenuPanel> {
  final _node = FocusScopeNode(debugLabel: 'submenu');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _node.requestFocus();
      if (_node.focusedChild == null) _node.nextFocus();
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.reduced(context, AppMotion.fast),
      curve: AppMotion.entrance,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: TapRegion(
        groupId: widget.groupId,
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                widget.onClose();
                return null;
              },
            ),
          },
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
              SingleActivator(LogicalKeyboardKey.arrowLeft): DismissIntent(),
            },
            child: FocusScope(
              node: _node,
              child: FocusTraversalGroup(
                child: SingleChildScrollView(
                  child: AppMenu(
                    key: const Key('menu-submenu-panel'),
                    width: widget.width,
                    children: widget.builder(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
