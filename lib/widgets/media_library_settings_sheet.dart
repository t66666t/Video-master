import 'dart:async';

import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../services/bilibili/bilibili_streaming_service.dart';
import 'package:provider/provider.dart';

String _formatStorageBytes(int bytes) {
  if (bytes <= 0) return '0 KB';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : (value >= 100 ? 0 : 1);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Opens the global media-library settings using the same bottom-sheet
/// presentation as the card-style controls.
void showMediaLibrarySettingsBottomSheet(
  BuildContext context,
  SettingsService settings,
) {
  final streamService = Provider.of<BilibiliStreamingService>(
    context,
    listen: false,
  );
  Future<BilibiliStreamCacheReport> cacheReportFuture = streamService
      .inspectCache();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1E1E1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) {
      var copyImportedMedia = settings.copyImportedMediaToPrivateStorage;
      return StatefulBuilder(
        builder: (context, setSheetState) {
          final maxHeight = MediaQuery.sizeOf(context).height * 0.65;
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
              children: [
                const Text(
                  '媒体库设置',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                Material(
                  color: const Color(0xFF292929),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: SwitchListTile.adaptive(
                    value: copyImportedMedia,
                    activeThumbColor: Colors.blueAccent,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    title: const Text(
                      '导入时复制媒体到应用私有目录',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    subtitle: const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '开启后，新导入的媒体会先完整复制到软件管理的目录，并直接使用副本播放。原文件不会被修改。',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                    onChanged: (value) {
                      // updateSetting applies the runtime value synchronously,
                      // notifies all listeners, then persists it asynchronously.
                      setSheetState(() => copyImportedMedia = value);
                      unawaited(
                        settings.updateSetting(
                          'copyImportedMediaToPrivateStorage',
                          value,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Material(
                  color: const Color(0xFF292929),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: FutureBuilder<BilibiliStreamCacheReport>(
                    future: cacheReportFuture,
                    builder: (context, snapshot) {
                      final report = snapshot.data;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 4,
                        ),
                        leading: const Icon(
                          Icons.cloud_download_outlined,
                          color: Colors.white70,
                        ),
                        title: const Text(
                          'Bilibili 在线播放缓存',
                          style: TextStyle(color: Colors.white, fontSize: 15),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            snapshot.connectionState == ConnectionState.waiting
                                ? '正在统计...'
                                : '${_formatStorageBytes(report?.bytes ?? 0)} · ${report?.fileCount ?? 0} 个缓存片段',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        trailing: TextButton(
                          onPressed:
                              snapshot.connectionState ==
                                  ConnectionState.waiting
                              ? null
                              : () async {
                                  await streamService.clearCache();
                                  setSheetState(() {
                                    cacheReportFuture = streamService
                                        .inspectCache();
                                  });
                                },
                          child: const Text('清除'),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '仅影响开关变更后新开始的导入任务；不会搬迁已有媒体。副本会占用额外空间，移入回收站后仍会保留并计入占用空间，永久删除卡片时一并删除。',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '即使关闭，若系统只提供临时文件地址，软件仍会保存必要副本，以避免媒体在缓存清理后失效。',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
