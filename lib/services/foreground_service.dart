import 'dart:io';

import 'package:flutter/services.dart';

/// Android's foreground service while a reply is generated.
///
/// The service only keeps the process alive and shows a notification; the generation itself is
/// the same stream as before. On other platforms these calls do nothing.
class ForegroundService {
  static const _channel = MethodChannel('ai.arce.app/system');

  bool _running = false;

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running || !Platform.isAndroid) return;
    _running = true;
    try {
      await _channel.invokeMethod<void>('startForeground');
    } catch (_) {
      // no service in this build: generation still works while the app is in front
      _running = false;
    }
  }

  Future<void> stop() async {
    if (!_running || !Platform.isAndroid) return;
    _running = false;
    try {
      await _channel.invokeMethod<void>('stopForeground');
    } catch (_) {
      // already gone
    }
  }
}
