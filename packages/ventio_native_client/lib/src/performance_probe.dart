import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/widgets.dart';

/// Opt-in timing capture for comparable Windows release-build investigations.
/// Events contain workflow names, durations, timestamps, and outcomes only.
class VentioPerformanceProbe {
  VentioPerformanceProbe._();

  static final String? _path = _validatedTracePath();
  static Future<void> _writeTail = Future<void>.value();
  static bool get enabled => _path != null;

  static Future<T> measure<T>(String name, Future<T> Function() action) async {
    if (!enabled) return action();
    final timer = Stopwatch()..start();
    final timeline = developer.TimelineTask()..start(name);
    var outcome = 'success';
    try {
      return await action();
    } on Object {
      outcome = 'failure';
      rethrow;
    } finally {
      timer.stop();
      timeline.finish();
      await _write(name, timer.elapsedMicroseconds, outcome);
    }
  }

  static void event(String name) {
    if (!enabled) return;
    unawaited(_write(name, 0, 'event'));
  }

  static Future<void> measureNavigation(Route<dynamic> route) {
    if (!enabled || route is! TransitionRoute<dynamic>) {
      return Future<void>.value();
    }
    final animation = route.animation;
    if (animation == null) return Future<void>.value();
    final label = route.settings.name ?? route.runtimeType.toString();
    return measure('navigation.$label', () async {
      final completed = Completer<void>();
      void onStatus(AnimationStatus status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          if (!completed.isCompleted) completed.complete();
        }
      }

      animation.addStatusListener(onStatus);
      onStatus(animation.status);
      try {
        await completed.future;
      } finally {
        animation.removeStatusListener(onStatus);
      }
    });
  }

  static String? _validatedTracePath() {
    final value = Platform.environment['VENTIO_PERF_TRACE_PATH']?.trim();
    if (value == null || value.isEmpty) return null;
    try {
      final path = File(value);
      if (!path.isAbsolute) return null;
      return path.path;
    } on Object {
      return null;
    }
  }

  static Future<void> _write(
    String name,
    int elapsedMicroseconds,
    String outcome,
  ) {
    final path = _path;
    if (path == null) return Future<void>.value();
    final write = _writeTail.then((_) async {
      try {
        await File(path).writeAsString(
          '${jsonEncode({'atUtc': DateTime.now().toUtc().toIso8601String(), 'workflow': name, 'elapsedMs': elapsedMicroseconds / 1000, 'outcome': outcome})}\n',
          mode: FileMode.append,
          flush: true,
        );
      } on Object {
        // Performance capture must not change application behavior.
      }
    });
    _writeTail = write;
    return write;
  }
}
