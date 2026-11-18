/// Vote over several speech segments, then keep one language for the film.
/// Empty/noisy results never silently turn into Japanese.
class VideoLanguage {
  VideoLanguage(String initial) : code = normalize(initial);

  String code;
  final _votes = <String, double>{};
  int _samples = 0;
  bool get locked => code != 'auto';

  static String normalize(String value) =>
      switch (value.toLowerCase().replaceAll(RegExp(r'[<>|]'), '').trim()) {
        'ja' || 'jp' || 'japanese' => 'ja',
        'zh' || 'chinese' || 'mandarin' => 'zh',
        'yue' || 'cantonese' => 'yue',
        'ko' || 'korean' => 'ko',
        'en' || 'english' => 'en',
        _ => 'auto',
      };

  bool observe(String language, double seconds) {
    if (locked) return false;
    final candidate = normalize(language);
    if (candidate == 'auto' || seconds < 0.5) return false;
    _votes.update(
      candidate,
      (n) => n + seconds.clamp(0.5, 8),
      ifAbsent: () => seconds.clamp(0.5, 8).toDouble(),
    );
    _samples++;
    final best = _votes.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final total = _votes.values.fold(0.0, (a, b) => a + b);
    if (_samples < 3 || total < 4 || best.value / total < 0.75) return false;
    code = best.key;
    return true;
  }

  void select(String value) {
    code = normalize(value);
    _votes.clear();
    _samples = 0;
  }
}
