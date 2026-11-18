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
  /// ffmpeg is network/disk bound: films waiting for a recogniser keep
  /// fetching their audio meanwhile (before links expire).
  static final extraction = PipelineStage(4);

  /// Recognisers by priority (see [PrioritySlots]); 1 under memory pressure.
  static final recognizers = PrioritySlots(2);
  static final translation = PipelineStage(3);
}

/// Speech recognisers (CPU, ~300 MB each) shared by every film, handed
/// out by priority rather than first come, first served:
///
/// - 0: the stretch just ahead of the viewer of the video on screen;
/// - 1: the rest ahead of that video;
/// - 2: background (other films, filling stretches behind).
///
/// When a more urgent request waits and every recogniser is taken, the
/// least urgent holder is asked to give its recogniser back (it stops at
/// its current piece and queues again); work of equal priority is never
/// interrupted. Priorities are read when deciding, so a seek or a switch
/// of tab takes effect at the next [reprioritize].
class PrioritySlots {
  PrioritySlots(this._capacity);
  int _capacity;
  int _seq = 0;
  final _holders = <_SlotTicket>[];
  final _waiting = <_SlotTicket>[];

  int get capacity => _capacity;
  set capacity(int value) {
    if (value == _capacity) return;
    _capacity = value;
    reprioritize();
  }

  /// Holders and waiters, for tests and the progress panel.
  int get holding => _holders.length;
  int get waiting => _waiting.length;

  Future<void Function()> acquire({
    required int Function() priority,
    required void Function() onPreempt,
    Future<void>? cancelled,
  }) {
    final ticket = _SlotTicket(_seq++, priority, onPreempt);
    _waiting.add(ticket);
    cancelled?.then((_) {
      if (ticket.granted.isCompleted) return;
      _waiting.remove(ticket);
      ticket.granted.complete(() {});
      reprioritize();
    });
    scheduleMicrotask(reprioritize);
    return ticket.granted.future;
  }

  int _order(_SlotTicket a, _SlotTicket b) {
    final byPriority = a.priority().compareTo(b.priority());
    return byPriority != 0 ? byPriority : a.seq.compareTo(b.seq);
  }

  void reprioritize() {
    _waiting.sort(_order);
    while (_holders.length < _capacity && _waiting.isNotEmpty) {
      _grant(_waiting.removeAt(0));
    }
    // Too many holders (capacity lowered) or someone more urgent waiting:
    // ask the least urgent holder to give way.
    final candidates = _holders.where((h) => !h.preempting).toList()
      ..sort((a, b) => _order(b, a));
    if (candidates.isEmpty) return;
    final worst = candidates.first;
    final over = _holders.length > _capacity;
    final outranked =
        _waiting.isNotEmpty && worst.priority() > _waiting.first.priority();
    if (over || outranked) {
      worst.preempting = true;
      worst.onPreempt();
    }
  }

  void _grant(_SlotTicket t) {
    _holders.add(t);
    var released = false;
    t.granted.complete(() {
      if (released) return;
      released = true;
      _holders.remove(t);
      scheduleMicrotask(reprioritize);
    });
  }
}

class _SlotTicket {
  _SlotTicket(this.seq, this.priority, this.onPreempt);
  final int seq;
  final int Function() priority;
  final void Function() onPreempt;
  final granted = Completer<void Function()>();
  bool preempting = false;
}
