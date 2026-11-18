import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video/services/app_settings.dart';
import 'package:video/services/openrouter_translator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'link destination and parallel subtitles persist independently',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = AppSettings();
      await first.load();
      expect(first.backgroundLinks, false);
      expect(first.parallelSubtitles, true);
      first.setBackgroundLinks(true);
      first.setParallelSubtitles(false);
      final second = AppSettings();
      await second.load();
      expect(second.backgroundLinks, true);
      expect(second.parallelSubtitles, false);
    },
  );

  test('Mistral Small is the default for both AI sources', () async {
    SharedPreferences.setMockInitialValues({});
    final s = AppSettings();
    await s.load();
    expect(s.modelFor(kOpenRouter), 'mistralai/mistral-small-3.2-24b-instruct');
    expect(s.modelFor(kVercel), 'mistral/mistral-small');
  });

  test('old defaults move to Mistral Small once; own choices stay', () async {
    SharedPreferences.setMockInitialValues({
      'openRouterModel': 'qwen/qwen3.7-flash',
      'vercelModel': 'mistral/mistral-nemo',
    });
    final s = AppSettings();
    await s.load();
    expect(s.modelFor(kOpenRouter), kDefaultOpenRouterModel);
    expect(s.modelFor(kVercel), kVercel.defaultModel);

    // Chosen again afterwards: kept, the move happens only once.
    s.setModel(kVercel, 'mistral/mistral-nemo');
    final again = AppSettings();
    await again.load();
    expect(again.modelFor(kVercel), 'mistral/mistral-nemo');

    SharedPreferences.setMockInitialValues({
      'openRouterModel': 'deepseek/deepseek-v4-flash',
    });
    final own = AppSettings();
    await own.load();
    expect(own.modelFor(kOpenRouter), 'deepseek/deepseek-v4-flash');
  });
}
