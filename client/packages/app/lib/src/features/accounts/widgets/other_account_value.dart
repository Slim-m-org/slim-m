// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A live value from an account that is not on screen.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// [builder] over [provider] in another account's [container]. Listened to,
/// since a second scope over a container the call pill scopes trips Flutter.
class OtherAccountValue<T> extends StatefulWidget {
  const OtherAccountValue({
    super.key,
    required this.container,
    required this.provider,
    required this.builder,
  });

  final ProviderContainer container;
  final ProviderListenable<T> provider;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<OtherAccountValue<T>> createState() => _OtherAccountValueState<T>();
}

class _OtherAccountValueState<T> extends State<OtherAccountValue<T>> {
  late ProviderSubscription<T> _subscription;
  late T _value;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    _subscription = widget.container.listen<T>(
      widget.provider,
      (_, next) => _changed(next),
    );
    _value = _subscription.read();
  }

  void _changed(T next) {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      setState(() => _value = next);
      return;
    }
    binding.addPostFrameCallback((_) {
      if (mounted) setState(() => _value = next);
    });
  }

  @override
  void didUpdateWidget(OtherAccountValue<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.container == widget.container &&
        oldWidget.provider == widget.provider) {
      return;
    }
    _subscription.close();
    _subscribe();
  }

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
