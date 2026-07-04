import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/temporary_storage_cleanup_models.dart';
import 'package:video_player_app/services/transcription_manager.dart';

class TemporaryStorageCleanupService {
  final TranscriptionManager transcriptionManager;
  final LibraryService libraryService;
  final BilibiliDownloadService bilibiliDownloadService;
  final YtDlpDownloadService ytDlpDownloadService;

  const TemporaryStorageCleanupService({
    required this.transcriptionManager,
    required this.libraryService,
    required this.bilibiliDownloadService,
    required this.ytDlpDownloadService,
  });

  Future<TemporaryStorageScanReport> scan() async {
    final categories = await Future.wait([
      transcriptionManager.buildTemporaryStorageReport(),
      libraryService.buildArchiveTemporaryStorageReport(),
      bilibiliDownloadService.buildTemporaryStorageReport(),
      ytDlpDownloadService.buildTemporaryStorageReport(),
    ]);
    return TemporaryStorageScanReport(
      categories: categories.where((item) => item.hasVisibleContent).toList(),
    );
  }

  Future<TemporaryStorageScanReport> clearAll() async {
    await transcriptionManager.clearTemporaryStorageArtifacts();
    await libraryService.clearArchiveTemporaryStorageArtifacts();
    await bilibiliDownloadService.clearTemporaryStorageArtifacts();
    await ytDlpDownloadService.clearTemporaryStorageArtifacts();
    return scan();
  }
}
