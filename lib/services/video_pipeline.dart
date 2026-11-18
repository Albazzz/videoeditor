import 'dart:async';
import 'dart:collection';

/// Each stage has its own capacity. A film reaching translation does not
/// block another film's recognition. Within a stage, ready films take turns.
class PipelineStage {
  PipelineStage(this.capacity);
  final int capacity;
  int _active = 0;
  final _waiting = <String, Queue<Completer<void Function()>>>{};
  String? _last;

  Future<void Function()> acquire(String videoId, {Future<void>? cancelled}) {
    final request = Completer<void Function()>();
    _waiting.putIfAbsent(videoId, Queue.new).add(request);
    cancelled?.then((_) {
      if (request.isCompleted) return;
      final queue = _waiting[videoId];
      queue?.remove(request);
      if (queue?.isEmpty == true) _waiting.remove(videoId);
      request.complete(() {});
      _drain();
    });
    scheduleMicrotask(_drain);
    return request.future;
  }

  void _drain() {
    while (_active < capacity && _waiting.isNotEmpty) {
      final keys = _waiting.keys.toList();
      final key = keys.firstWhere((k) => k != _last, orElse: () => keys.first);
      final queue = _waiting.remove(key)!;
      final next = queue.removeFirst();
      if (queue.isNotEmpty) _waiting[key] = queue;
      _last = key;
      _active++;
      var released = false;
      next.complete(() {
        if (released) return;
        released = true;
        _active--;
        scheduleMicrotask(_drain);
      });
    }
  }

  Future<T> run<T>(
    String videoId,
    Future<T> Function() action, {
    Future<void>? cancelled,
  }) async {
    final release = await acquire(videoId, cancelled: cancelled);
    try {
      return await action();
    } finally {
      release();
    }
  }
}

class VideoPipeline {
  static final extraction = PipelineStage(2);
  static final recognizers = PipelineStage(2);
  static final recognition = PipelineStage(2);
  static final translation = PipelineStage(3);
}
