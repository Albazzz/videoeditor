import 'dart:async';
import 'package:flutter/material.dart';
import '../models/cue.dart';
import '../services/app_settings.dart';
import '../services/subtitle_revision.dart';
import '../services/translator.dart';
import 'common.dart';

Future<void> showSubtitleRevision(
  BuildContext context, {
  required String videoId,
  required String language,
  required List<Cue> Function() currentCues,
  required Future<void> Function(List<Cue>) onApply,
  int? initialIndex,
  Cue? initialCue,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _RevisionSheet(
    videoId: videoId,
    language: language,
    currentCues: currentCues,
    onApply: onApply,
    initialIndex: initialIndex,
    initialCue: initialCue,
  ),
);

class _RevisionSheet extends StatefulWidget {
  const _RevisionSheet({
    required this.videoId,
    required this.language,
    required this.currentCues,
    required this.onApply,
    this.initialIndex,
    this.initialCue,
  });
  final String videoId, language;
  final List<Cue> Function() currentCues;
  final Future<void> Function(List<Cue>) onApply;
  final int? initialIndex;
  final Cue? initialCue;
  @override
  State<_RevisionSheet> createState() => _RevisionSheetState();
}

class _RevisionSheetState extends State<_RevisionSheet> {
  late final List<Cue> _basis;
  int? get _initialIndex => widget.initialCue == null
      ? widget.initialIndex
      : _basis.indexWhere(
          (c) =>
              c.start == widget.initialCue!.start &&
              c.end == widget.initialCue!.end &&
              c.source == widget.initialCue!.source,
        );
  final _instruction = TextEditingController();
  late final _from = TextEditingController(text: '${(_initialIndex ?? 0) + 1}');
  late final _to = TextEditingController(text: '${(_initialIndex ?? 0) + 1}');
  late String _scope = _initialIndex == null ? 'all' : 'one';
  Translator? _translator;
  CueRevision? _draft;
  String? _error;
  bool _busy = false, _applied = false;
  int _done = 0;

  @override
  void initState() {
    super.initState();
    _basis = List.of(widget.currentCues());
  }

  @override
  void dispose() {
    unawaited(_translator?.dispose());
    _instruction.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_busy) return;
    if (!appSettings.useCloud) {
      setState(
        () => _error =
            'Chọn OpenRouter hoặc Vercel và nhập key trong Cài đặt dịch để yêu cầu AI dịch lại.',
      );
      return;
    }
    final cues = List.of(_scope == 'all' ? widget.currentCues() : _basis);
    final first = _scope == 'all' ? 0 : (int.tryParse(_from.text) ?? 0) - 1;
    final last = _scope == 'all'
        ? cues.length - 1
        : _scope == 'one'
        ? first
        : (int.tryParse(_to.text) ?? 0) - 1;
    if (first < 0 || last < first || last >= cues.length) {
      setState(() => _error = 'Số câu không hợp lệ (1–${cues.length}).');
      return;
    }
    final nearby = [
      for (var i = (first - 4).clamp(0, cues.length); i < first; i++)
        (cues[i].source, cues[i].text),
    ];
    final translator = Translator.create(
      force: true,
      videoId: widget.videoId,
      additionalInstruction: _instruction.text.trim(),
      contextBefore: nearby,
    );
    _translator = translator;
    setState(() {
      _busy = true;
      _done = 0;
      _error = null;
      _draft = null;
      _applied = false;
    });
    try {
      final draft = await CueRevision.generate(
        videoId: widget.videoId,
        cues: cues,
        indices: [for (var i = first; i <= last; i++) i],
        language: widget.language,
        translator: translator,
        onProgress: (n) {
          if (mounted) setState(() => _done = n);
        },
      );
      if (mounted) setState(() => _draft = draft);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      await translator.dispose();
      if (mounted) {
        setState(() {
          _busy = false;
          _translator = null;
        });
      }
    }
  }

  Future<void> _apply({bool undo = false}) async {
    final draft = _draft;
    if (draft == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = draft.apply(
        widget.videoId,
        widget.currentCues(),
        undo: undo,
      );
      await widget.onApply(next);
      if (mounted) setState(() => _applied = !undo);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SizedBox(
          height:
              (MediaQuery.sizeOf(context).height * .85 -
                      MediaQuery.viewInsetsOf(context).bottom -
                      16)
                  .clamp(80.0, MediaQuery.sizeOf(context).height),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Dịch lại phụ đề',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _scope,
                  decoration: const InputDecoration(labelText: 'Phạm vi'),
                  items: const [
                    DropdownMenuItem(value: 'one', child: Text('Một câu')),
                    DropdownMenuItem(value: 'range', child: Text('Một đoạn')),
                    DropdownMenuItem(
                      value: 'all',
                      child: Text('Toàn bộ phụ đề'),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                          _scope = v!;
                          _draft = null;
                        }),
                ),
                if (_scope != 'all')
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _from,
                          enabled: !_busy,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: _scope == 'one' ? 'Câu số' : 'Từ câu',
                          ),
                        ),
                      ),
                      if (_scope == 'range') ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _to,
                            enabled: !_busy,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Đến câu',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                TextField(
                  controller: _instruction,
                  enabled: !_busy,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Yêu cầu dịch lại',
                    hintText: 'Ví dụ: sát nghĩa hơn, đổi xưng hô thành anh–em',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Giữ lời gốc, thời gian và mức độ diễn đạt; không nói giảm hay che lời tục.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_busy) ...[
                  const LinearProgressIndicator(),
                  Text('Đã xử lý $_done câu…'),
                ],
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                SizedBox(
                  height: draft == null ? 64 : 220,
                  child: draft == null
                      ? const Center(
                          child: Text(
                            'Tạo bản dịch mới để xem trước khi áp dụng.',
                          ),
                        )
                      : ListView.builder(
                          itemCount: draft.before.length,
                          itemBuilder: (_, i) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(formatTime(draft.before[i].start)),
                                SelectableText(
                                  'Gốc: ${draft.before[i].source}',
                                ),
                                SelectableText('Cũ: ${draft.before[i].text}'),
                                SelectableText(
                                  'Mới: ${draft.after[i].text}',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    if (_busy && _translator != null)
                      TextButton(
                        onPressed: () => _translator?.dispose(),
                        child: const Text('Huỷ dịch'),
                      ),
                    OutlinedButton(
                      onPressed: _busy ? null : _generate,
                      child: const Text('Tạo bản dịch mới'),
                    ),
                    if (draft != null)
                      FilledButton(
                        onPressed: _busy ? null : () => _apply(undo: _applied),
                        child: Text(_applied ? 'Hoàn tác' : 'Áp dụng'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
