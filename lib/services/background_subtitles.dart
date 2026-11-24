import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';

class SubtitleBatchProgress {
  const SubtitleBatchProgress({
    this.completed = 0,
    this.total = 0,
    this.active = false,
    this.progress = 0,
    this.canDismiss = true,
  });
  final int completed, total, progress;
  final bool active;
  final bool canDismiss;
  String get label => 'Sub: $completed/$total hoàn thành';

  Map<String, Object> get payload => {
    'completed': completed,
    'total': total,
    'active': active,
    'progress': progress,
  };
}

class _Job {
  bool done = false, active = true, cancelled = false;
  double fraction = 0;
}

/// The native boundary accepts counts only: never titles, URLs, keys or IDs.
class BackgroundSubtitles {
  BackgroundSubtitles({MethodChannel? channel, bool? enabled})
    : _channel = channel ?? const MethodChannel('vsub/subtitle_progress'),
      _enabled = enabled ?? (Platform.isAndroid || Platform.isIOS);
  static final instance = BackgroundSubtitles();
  final MethodChannel _channel;
  final bool _enabled;
  final state = ValueNotifier(const SubtitleBatchProgress());
  final _jobs = <Object, _Job>{};
  Future<void> _sending = Future.value();
  Timer? _soon;
  String? _sent;
  bool _cancelling = false;

  void initialize({
    required Future<void> Function() onCancel,
    required VoidCallback onOpen,
  }) {
    if (!_enabled) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cancel') {
        _cancelling = true;
        _soon?.cancel();
        _soon = null;
        try {
          await onCancel();
        } finally {
          _cancelling = false;
          _sent = null;
          _send();
        }
      }
      if (call.method == 'open') onOpen();
    });
    unawaited(
      _channel
          .invokeMethod<bool>('opened')
          .then((opened) {
            if (opened == true) onOpen();
          })
          .catchError((Object _) {}),
    );
  }

  void begin(Object job) {
    if (_jobs.isNotEmpty && _jobs.values.every((j) => j.done || j.cancelled)) {
      _jobs.clear();
    }
    _jobs.putIfAbsent(job, _Job.new);
    _publish(immediate: true);
  }

  void update(Object job, {required bool active, required double fraction}) {
    final entry = _jobs[job];
    if (entry == null || entry.done || entry.cancelled) return;
    entry.active = active;
    entry.fraction = fraction.clamp(0.0, 0.9999);
    _publish();
  }

  void finish(Object job) {
    final entry = _jobs.remove(job);
    if (entry == null || entry.done || entry.cancelled) return;
    entry.done = true;
    entry.active = false;
    entry.fraction = 1;
    _jobs[Object()] = entry;
    _publish(immediate: true);
  }

  void cancel(Object job) {
    final entry = _jobs.remove(job);
    if (entry == null || entry.done) return;
    entry.cancelled = true;
    entry.active = false;
    _jobs[Object()] = entry;
    _publish(immediate: true);
  }

  void dismiss() {
    if (_jobs.values.any((j) => !j.done && !j.cancelled)) return;
    _jobs.clear();
    _publish(immediate: true);
  }

  void refreshNative() {
    _sent = null;
    if (_enabled) _send();
  }

  void _publish({bool immediate = false}) {
    final total = _jobs.length;
    final completed = _jobs.values.where((j) => j.done).length;
    final progress = total == 0
        ? 0
        : (_jobs.values.fold<double>(0, (sum, j) => sum + j.fraction) /
                  total *
                  10000)
              .floor();
    state.value = SubtitleBatchProgress(
      completed: completed,
      total: total,
      active: _jobs.values.any((j) => j.active),
      progress: progress,
      canDismiss: _jobs.values.every((j) => j.done || j.cancelled),
    );
    if (!_enabled) return;
    if (immediate) {
      _soon?.cancel();
      _soon = null;
      _send();
    } else {
      _soon ??= Timer(const Duration(seconds: 1), () {
        _soon = null;
        _send();
      });
    }
  }

  void _send() {
    if (_cancelling) return;
    final snapshot = state.value;
    final signature =
        '${snapshot.completed}/${snapshot.total}/${snapshot.active}/${snapshot.progress}';
    if (_sent == signature) return;
    _sent = signature;
    _sending = _sending.then((_) async {
      try {
        await _channel.invokeMethod<void>('update', snapshot.payload);
      } on MissingPluginException {
        // Desktop and older builds still show the in-app count.
      } catch (e) {
        _sent = null;
        AppLog.e('sub nền', 'Chưa cập nhật được thông báo: $e');
      }
    });
  }

  @visibleForTesting
  Future<void> flush() async {
    _soon?.cancel();
    _soon = null;
    _send();
    await _sending;
  }
}
