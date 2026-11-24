import 'package:flutter/material.dart';

import '../services/active_work.dart';
import '../services/open_page.dart';
import '../services/subtitle_resume.dart';
import '../services/subtitle_store.dart';
import '../services/retained_audio.dart';
import '../services/subtitle_session.dart';
import '../services/video_library.dart';
import 'common.dart';

/// Only a confirmed absence of usable local input sends the user to the source.
Future<SubtitleResumeResult?> resumeSavedSubtitles(
  BuildContext context,
  SavedSubs saved, {
  bool openSource = true,
  SubtitleResume? service,
  bool hidden = false,
  Future<void> Function(SubtitleSession)? onSave,
}) async {
  try {
    final result = await (service ?? SubtitleResume.instance).resume(
      saved,
      ensureRecognition: () => ensureModels(context),
      hidden: hidden,
      onSave: onSave,
    );
    if (!context.mounted) return result;
    switch (result) {
      case SubtitleResumeResult.started:
        toast(context, 'Đang làm tiếp trong app từ dữ liệu đã lưu');
      case SubtitleResumeResult.alreadyRunning:
        toast(context, 'Phụ đề này đang được xử lý trong app');
      case SubtitleResumeResult.needsSource:
        if (openSource && saved.page.startsWith('http')) {
          requestResume(saved.page);
          toast(
            context,
            'Thiếu âm thanh cho đoạn còn lại, mở trang để lấy tiếp',
          );
        } else if (openSource) {
          toast(
            context,
            'Còn thiếu âm thanh của một số đoạn; dữ liệu đã làm vẫn được giữ',
          );
        }
      case SubtitleResumeResult.complete:
        toast(context, 'Phụ đề này đã hoàn tất');
      case SubtitleResumeResult.cancelled:
        break;
    }
    return result;
  } catch (e) {
    if (context.mounted) toast(context, 'Chưa làm tiếp được: $e');
    return null;
  }
}

Future<SubtitleResumeResult?> resumeStoredSubtitles(
  BuildContext context,
  String id, {
  bool openSource = true,
  RetainedAudioStore? audioStore,
  bool includeHidden = false,
}) async {
  try {
    await ActiveWork.waitForAudio(id);
    VideoItem? item;
    if (id.startsWith('file:')) {
      final videos = [
        ...await VideoLibrary.list(hidden: false),
        if (includeHidden) ...await VideoLibrary.list(hidden: true),
      ];
      item = videos
          .where((v) => 'file:${v.file.absolute.path}' == id)
          .firstOrNull;
      if (item == null) {
        if (context.mounted) {
          toast(context, 'Không tìm thấy video trong thư viện');
        }
        return null;
      }
    }
    var saved = item == null
        ? await SubtitleStore.load(id)
        : await VideoLibrary.loadSubtitleState(item);
    var hidden = item?.hidden ?? false;
    if (saved == null) {
      final recordings = await (audioStore ?? RetainedAudioStore.instance).list(
        videoId: id,
        includeHidden: includeHidden,
      );
      final audio = recordings.firstOrNull;
      if (audio == null || audio.bytes == 0) {
        if (context.mounted) {
          toast(context, 'Không tìm thấy phụ đề hoặc âm thanh đã lưu');
        }
        return null;
      }
      hidden = hidden || audio.hidden;
      saved = SavedSubs(
        id: id,
        title: audio.title,
        page: audio.page.isEmpty ? 'audio:$id' : audio.page,
        source: audio.source,
        language: audio.language.isEmpty ? 'auto' : audio.language,
        duration: audio.duration,
        updated: DateTime.now(),
        cues: const [],
        covered: const [],
      );
    }
    if (!context.mounted) return null;
    return resumeSavedSubtitles(
      context,
      saved,
      openSource: openSource,
      service: audioStore == null ? null : SubtitleResume(audio: audioStore),
      hidden: hidden,
      onSave: item == null
          ? null
          : (s) => VideoLibrary.saveCues(
              item!,
              List.of(s.cues),
              language: s.language,
              covered: s.covered,
              duration: s.duration,
              complete: coversWholeVideo(
                s.covered,
                s.duration,
                reachedEnd: s.reachedEnd,
              ),
              imported: false,
            ),
    );
  } catch (e) {
    if (context.mounted) toast(context, 'Chưa đọc được dữ liệu đã lưu: $e');
    return null;
  }
}
