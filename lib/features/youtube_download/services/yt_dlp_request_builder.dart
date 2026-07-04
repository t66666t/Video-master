import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_meta_parser.dart';

class YtDlpRequestBuilder {
  const YtDlpRequestBuilder();

  NativeDownloadRequest build({
    required String taskId,
    required String url,
    required VideoMeta meta,
    required DownloadSelection selection,
    required DownloadSessionConfig sessionConfig,
    required String outputDir,
  }) {
    final effectiveOutputContainer = _resolveEffectiveOutputContainer(
      selection,
    );
    final outputTemplate = '%(title)s__$taskId.%(ext)s';
    final args = <String>[
      '--no-warnings',
      '--newline',
      '--progress',
      '--force-overwrites',
      '--restrict-filenames',
      '--no-mtime',
      '--write-thumbnail',
      '--convert-thumbnails',
      'png',
      '--embed-metadata',
      '--print',
      'before_dl:__YTDLP_BEFORE_DL__:%(filepath,_filename|)s',
      '--print',
      'after_move:__YTDLP_AFTER_MOVE__:%(filepath,_filename|)s',
    ];

    final resolvedVideoId = _resolveVideoFormatId(meta, selection);
    final resolvedAudioIds = _resolveAudioFormatIds(meta, selection);
    final resolvedSubtitleTracks = _resolveSubtitleTracks(meta, selection);
    final resolvedSubtitleLanguages = _resolveSubtitleLanguages(
      meta,
      selection,
      resolvedSubtitleTracks,
    );

    args.addAll(_buildSessionArgs(sessionConfig));

    final extractorArgs = meta.source == 'youtube'
        ? buildYoutubeExtractorArgs(sessionConfig)
        : null;
    if (extractorArgs != null) {
      args.addAll(['--extractor-args', extractorArgs]);
    }

    args.addAll(['--paths', outputDir]);
    args.addAll(
      _buildFormatArgs(
        meta: meta,
        selection: selection,
        resolvedVideoId: resolvedVideoId,
        resolvedAudioIds: resolvedAudioIds,
      ),
    );
    args.addAll(
      _buildSubtitleArgs(
        meta: meta,
        selection: selection,
        resolvedSubtitleTracks: resolvedSubtitleTracks,
        resolvedSubtitleLanguages: resolvedSubtitleLanguages,
      ),
    );
    args.addAll(_buildPostProcessArgs(selection));
    args.addAll(['-o', outputTemplate]);
    args.add(url);

    return NativeDownloadRequest(
      taskId: taskId,
      url: url,
      outputDir: outputDir,
      outputTemplate: outputTemplate,
      args: args,
      debugContext: {
        'source': meta.source,
        'webpageUrl': meta.webpageUrl,
        'resolvedVideoFormatId': resolvedVideoId,
        'resolvedAudioFormatIds': resolvedAudioIds,
        'resolvedSubtitleLanguages': resolvedSubtitleLanguages,
        'resolvedSubtitleTrackKeys': resolvedSubtitleTracks
            .map((item) => item.selectionKey)
            .toList(),
        'resolvedSubtitleTracks': resolvedSubtitleTracks
            .map((item) => item.toJson())
            .toList(),
        'extractorArgs': extractorArgs,
        'outputContainer': effectiveOutputContainer,
        'audioOnly': selection.audioOnly,
        'compatibilityMode': selection.enableCompatibilityMode,
        'sessionConfigSummary': {
          'useCookies': sessionConfig.useCookies,
          'useProxy': sessionConfig.useProxy,
          'useCustomUserAgent': sessionConfig.useCustomUserAgent,
          'socketTimeoutSeconds': sessionConfig.socketTimeoutSeconds,
          'retries': sessionConfig.retries,
          'fragmentRetries': sessionConfig.fragmentRetries,
          'concurrentFragments': sessionConfig.concurrentFragments,
          'rateLimit': sessionConfig.rateLimit,
          'forceIpv4': sessionConfig.forceIpv4,
          'enabledPlayerClients': sessionConfig.enabledPlayerClients,
          'hasVisitorData': (sessionConfig.visitorData?.isNotEmpty ?? false),
          'enabledPoTokenCount': sessionConfig.poTokens
              .where((item) => item.enabled && item.hasValue)
              .length,
        },
      },
    );
  }

  List<String> _buildSessionArgs(DownloadSessionConfig sessionConfig) {
    final args = <String>[];
    if (sessionConfig.useCookies &&
        (sessionConfig.cookiesFilePath?.isNotEmpty ?? false)) {
      args.addAll(['--cookies', sessionConfig.cookiesFilePath!]);
    }
    if (sessionConfig.useProxy && (sessionConfig.proxy?.isNotEmpty ?? false)) {
      args.addAll(['--proxy', sessionConfig.proxy!]);
    }
    if ((sessionConfig.socketTimeoutSeconds ?? 0) > 0) {
      args.addAll([
        '--socket-timeout',
        sessionConfig.socketTimeoutSeconds!.toString(),
      ]);
    }
    if ((sessionConfig.retries ?? 0) > 0) {
      args.addAll(['--retries', sessionConfig.retries!.toString()]);
    }
    if ((sessionConfig.fragmentRetries ?? 0) > 0) {
      args.addAll([
        '--fragment-retries',
        sessionConfig.fragmentRetries!.toString(),
      ]);
    }
    if ((sessionConfig.concurrentFragments ?? 0) > 0) {
      args.addAll(['-N', sessionConfig.concurrentFragments!.toString()]);
    }
    if ((sessionConfig.rateLimit?.isNotEmpty ?? false)) {
      args.addAll(['-r', sessionConfig.rateLimit!]);
    }
    if (sessionConfig.forceIpv4) {
      args.add('-4');
    }
    if (sessionConfig.useCustomUserAgent &&
        (sessionConfig.userAgent?.isNotEmpty ?? false)) {
      args.addAll(['--add-header', 'User-Agent:${sessionConfig.userAgent!}']);
    }
    return args;
  }

  String? buildYoutubeExtractorArgs(DownloadSessionConfig config) {
    final parts = <String>[];
    final clients = config.enabledPlayerClients
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList();
    if (clients.isNotEmpty) {
      parts.add('player_client=${clients.join(',')}');
    }
    if ((config.visitorData?.isNotEmpty ?? false)) {
      parts.add('visitor_data=${config.visitorData!}');
    }
    final enabledTokens = config.poTokens
        .where((item) => item.enabled && item.hasValue)
        .map((item) => '${item.client}.${item.context}+${item.token}')
        .toList();
    if (enabledTokens.isNotEmpty) {
      parts.add('po_token=${enabledTokens.join(',')}');
    }
    if (parts.isEmpty) {
      return null;
    }
    return 'youtube:${parts.join(';')}';
  }

  List<String> _buildFormatArgs({
    required VideoMeta meta,
    required DownloadSelection selection,
    required String? resolvedVideoId,
    required List<String> resolvedAudioIds,
  }) {
    if (selection.audioOnly) {
      final audioId = resolvedAudioIds.isNotEmpty
          ? resolvedAudioIds.first
          : null;
      if (audioId != null) {
        return ['-f', audioId];
      }
      return ['-f', 'bestaudio'];
    }

    final videoId = resolvedVideoId;
    final audioId = resolvedAudioIds.isNotEmpty ? resolvedAudioIds.first : null;
    final selectedVideo = meta.videoFormats
        .where((item) => item.formatId == videoId)
        .toList();
    final selectedVideoHasAudio =
        selectedVideo.isNotEmpty && selectedVideo.first.hasAudio;
    final shouldMergeAudio =
        audioId != null &&
        (!selectedVideoHasAudio || selection.selectedAudioFormatIds.isNotEmpty);

    if (videoId != null && shouldMergeAudio) {
      return ['-f', '$videoId+$audioId'];
    }
    if (videoId != null) {
      return ['-f', videoId];
    }
    return ['-f', 'bestvideo+bestaudio/best'];
  }

  List<String> _buildSubtitleArgs({
    required VideoMeta meta,
    required DownloadSelection selection,
    required List<SubtitleTrack> resolvedSubtitleTracks,
    required List<String> resolvedSubtitleLanguages,
  }) {
    final args = <String>[];
    final wantsManualSubs =
        resolvedSubtitleTracks.any((item) => !item.isAutoGenerated) ||
        selection.writeSubtitles ||
        selection.embedSubtitles;
    final wantsAutoSubs =
        resolvedSubtitleTracks.any((item) => item.isAutoGenerated) ||
        selection.writeAutoSubtitles;
    final hasAnySubtitleSelection = resolvedSubtitleTracks.isNotEmpty;
    final hasAnySubtitlesInMeta = meta.subtitles.isNotEmpty;

    if (wantsManualSubs && hasAnySubtitlesInMeta) {
      args.add('--write-subs');
    }
    if (wantsAutoSubs) {
      args.add('--write-auto-subs');
    }
    if ((selection.embedSubtitles || hasAnySubtitleSelection) &&
        hasAnySubtitlesInMeta &&
        !selection.audioOnly) {
      args.add('--embed-subs');
    }
    if (hasAnySubtitleSelection) {
      args.addAll(['--sub-langs', resolvedSubtitleLanguages.join(',')]);
    }
    if (wantsManualSubs || wantsAutoSubs) {
      args.addAll(['--sub-format', 'srt/best']);
    }
    return args;
  }

  List<String> _buildPostProcessArgs(DownloadSelection selection) {
    final args = <String>[];
    final effectiveOutputContainer = _resolveEffectiveOutputContainer(
      selection,
    );
    if (selection.audioOnly) {
      if (effectiveOutputContainer != 'm4a' &&
          effectiveOutputContainer != 'best') {
        args.addAll([
          '--extract-audio',
          '--audio-format',
          effectiveOutputContainer,
        ]);
      }
      return args;
    }

    if (selection.enableCompatibilityMode) {
      args.addAll(['--merge-output-format', 'mkv']);
    } else if (effectiveOutputContainer.isNotEmpty) {
      args.addAll(['--merge-output-format', effectiveOutputContainer]);
    }

    if (selection.removeAudio) {
      args.addAll(['--postprocessor-args', 'ffmpeg:-an']);
    }
    return args;
  }

  String _resolveEffectiveOutputContainer(DownloadSelection selection) {
    if (selection.audioOnly) {
      final requested = selection.outputContainer.trim().toLowerCase();
      switch (requested) {
        case 'mp3':
        case 'aac':
        case 'm4a':
        case 'wav':
        case 'opus':
        case 'best':
          return requested;
        default:
          return 'm4a';
      }
    }
    return 'mkv';
  }

  String? _resolveVideoFormatId(VideoMeta meta, DownloadSelection selection) {
    if ((selection.selectedVideoFormatId?.isNotEmpty ?? false)) {
      return selection.selectedVideoFormatId;
    }
    if ((meta.recommendedVideoFormatId?.isNotEmpty ?? false)) {
      return meta.recommendedVideoFormatId;
    }
    return _pickDefaultVideoId(meta);
  }

  List<String> _resolveAudioFormatIds(
    VideoMeta meta,
    DownloadSelection selection,
  ) {
    if (selection.selectedAudioFormatIds.isNotEmpty) {
      return selection.selectedAudioFormatIds;
    }
    if ((meta.recommendedAudioFormatId?.isNotEmpty ?? false)) {
      return [meta.recommendedAudioFormatId!];
    }
    final fallback = _pickDefaultAudioId(meta);
    return fallback == null ? const [] : [fallback];
  }

  List<String> _resolveSubtitleLanguages(
    VideoMeta meta,
    DownloadSelection selection,
    List<SubtitleTrack> resolvedSubtitleTracks,
  ) {
    if (resolvedSubtitleTracks.isNotEmpty) {
      return _dedupeOrderedStrings(
        resolvedSubtitleTracks
            .map((item) => item.languageCode)
            .where((item) => item.trim().isNotEmpty),
      );
    }
    if (selection.subtitleLanguages.isNotEmpty) {
      return _dedupeOrderedStrings(selection.subtitleLanguages);
    }
    if (meta.recommendedSubtitleLanguages.isNotEmpty) {
      return _dedupeOrderedStrings(meta.recommendedSubtitleLanguages);
    }
    return const [];
  }

  List<SubtitleTrack> _resolveSubtitleTracks(
    VideoMeta meta,
    DownloadSelection selection,
  ) {
    if (selection.selectedSubtitleTrackKeys.isNotEmpty) {
      final byKey = {
        for (final track in meta.subtitles) track.selectionKey: track,
      };
      return selection.selectedSubtitleTrackKeys
          .map((item) => byKey[item])
          .whereType<SubtitleTrack>()
          .toList();
    }
    if (selection.subtitleLanguages.isNotEmpty) {
      return _resolveTracksForPreferredLanguages(
        meta.subtitles,
        selection.subtitleLanguages,
      );
    }
    if (meta.recommendedSubtitleLanguages.isEmpty) {
      return const [];
    }
    return _resolveTracksForPreferredLanguages(
      meta.subtitles,
      meta.recommendedSubtitleLanguages,
    );
  }

  List<SubtitleTrack> _resolveTracksForPreferredLanguages(
    List<SubtitleTrack> subtitles,
    List<String> preferredLanguages,
  ) {
    final used = <String>{};
    final tracks = <SubtitleTrack>[];
    for (final language in preferredLanguages) {
      final matches = subtitles.where(
        (item) => YtDlpMetaParser.matchesPreferenceLanguage(
          language,
          item.languageCode,
        ),
      );
      for (final track in matches) {
        if (used.add(track.selectionKey)) {
          tracks.add(track);
        }
      }
    }
    return tracks;
  }

  List<String> _dedupeOrderedStrings(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      result.add(trimmed);
    }
    return result;
  }

  String? _pickDefaultVideoId(VideoMeta meta) {
    if (meta.videoFormats.isEmpty) return null;
    final sorted = [...meta.videoFormats]
      ..sort((a, b) {
        final aScore = _videoPriorityScore(a);
        final bScore = _videoPriorityScore(b);
        return bScore.compareTo(aScore);
      });
    return sorted.first.formatId;
  }

  String? _pickDefaultAudioId(VideoMeta meta) {
    if (meta.audioFormats.isEmpty) return null;
    final sorted = [...meta.audioFormats]
      ..sort((a, b) {
        final aScore = _audioPriorityScore(a);
        final bScore = _audioPriorityScore(b);
        return bScore.compareTo(aScore);
      });
    return sorted.first.formatId;
  }

  int _videoPriorityScore(VideoFormat format) {
    int score = 0;
    if (format.ext == 'mp4') score += 40;
    final codec = (format.videoCodec ?? '').toLowerCase();
    if (codec.contains('avc') || codec.contains('h264')) score += 30;
    if (format.hasAudio) score += 20;
    score += (format.height ?? 0);
    return score;
  }

  int _audioPriorityScore(AudioFormat format) {
    int score = 0;
    if (format.isDefaultTrack) score += 20;
    if ((format.language ?? '').toLowerCase().startsWith('zh')) score += 15;
    if (format.ext == 'm4a') score += 12;
    final codec = (format.audioCodec ?? '').toLowerCase();
    if (codec.contains('aac')) score += 10;
    if (codec.contains('opus')) score += 5;
    score += format.bitrate ?? 0;
    return score;
  }
}
