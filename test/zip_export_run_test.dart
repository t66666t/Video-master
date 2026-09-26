import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/features/portable_transfer/zip_media_exporter.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('zip export byte-copies a card title and leaves no scratch files', () async {
    final originalProvider = PathProviderPlatform.instance;
    final root = await Directory.systemTemp.createTemp('zip_export_run_');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    addTearDown(() async {
      PathProviderPlatform.instance = originalProvider;
      if (await root.exists()) await root.delete(recursive: true);
    });

    final library = LibraryService();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    addTearDown(library.resetLibraryForTesting);
    final media = File(p.join(root.path, 'disk-name.mp4'));
    await media.writeAsString('video-bytes');
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: media.path,
        title: '卡片名',
        durationMs: 1000,
        lastUpdated: 1,
        parentId: 'pending',
        hasProbedChapters: true,
      ),
    );
    await library.moveItemToCollection('clip', null);

    final service = PortableTransferService.forTesting();
    final output = p.join(root.path, 'out.zip');
    final task = await service.exportSelection(
      library: library,
      rootIds: const <String>['clip'],
      outputPath: output,
      options: const PortableExportOptions(
        packageName: '我的导出',
        format: PortableExportFormat.zip,
        zipEmbedSubtitles: false,
        zipExternalSubtitles: false,
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (task.isActive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(task.status, PortableTransferStatus.completed, reason: task.error);
    final archive = ZipDecoder().decodeBytes(await File(output).readAsBytes());
    expect(
      archive.files.map((file) => file.name),
      contains('卡片名.mp4'),
    );
    expect(archive.files.single.content, 'video-bytes'.codeUnits);
    expect(
      await Directory(p.join(root.path, zipExportScratchDirectoryName)).exists(),
      isFalse,
    );
    expect(await File('$output.part').exists(), isFalse);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationSupportPath() async => rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;

  @override
  Future<String?> getDownloadsPath() async => rootPath;
}
