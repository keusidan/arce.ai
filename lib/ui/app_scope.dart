import 'package:flutter/widgets.dart';

import '../services/app_controller.dart';

/// Gives widgets access to the [AppController]. It does not rebuild by itself: widgets listen
/// to the specific part they show (chat, settings, models, updates).
class ArceScope extends InheritedWidget {
  const ArceScope({super.key, required this.app, required super.child});

  final AppController app;

  static AppController of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ArceScope>();
    assert(scope != null, 'ArceScope is missing above this widget');
    return scope!.app;
  }

  @override
  bool updateShouldNotify(ArceScope oldWidget) => app != oldWidget.app;
}
