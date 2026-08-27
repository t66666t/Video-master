import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/services/video_compose/video_compose_ass_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';

VideoComposeRequest _request({
  VideoComposeRenderMode mode = VideoComposeRenderMode.precise,
}) {
  return VideoComposeRequest(
    videoId: 'video',
    videoPath: 'input.mp4',
    title: 'test',
    primarySubtitlePath: 'test.srt',
    renderSecondarySubtitle: false,
    continuousSubtitle: false,
    embedSoftSubtitles: false,
    softSubtitleOnly: false,
    softSubtitleUseSourceQuality: true,
    softSubtitleTracks: const <VideoComposeSoftSubtitleTrack>[],
    resolution: VideoComposeResolution.p1080,
    renderMode: mode,
    subtitleStyle: const SubtitleStyle(),
    subtitleStylePortrait: const SubtitleStyle(
      layoutStyle: SubtitleLayoutStyle(fontSize: 33),
    ),
    subtitleAlignment: const Alignment(0, 0.8),
    splitSubtitleByLine: true,
    outputPath: 'output.mp4',
  );
}

void main() {
  test(
    'render mode is string serialized and legacy tasks remain approximate',
    () {
      final Map<String, dynamic> json = _request().toJson();
      expect(json['renderMode'], 'precise');
      expect(
        VideoComposeRequest.fromJson(json).renderMode,
        VideoComposeRenderMode.precise,
      );

      json.remove('renderMode');
      expect(
        VideoComposeRequest.fromJson(json).renderMode,
        VideoComposeRenderMode.approximate,
      );
    },
  );

  test('portrait canvas uses the ordinary portrait style snapshot', () {
    final VideoComposeRequest request = _request();
    expect(request.styleForCanvas(width: 1080, height: 1920).fontSize, 33);
    expect(
      request.styleForCanvas(width: 1920, height: 1080).fontSize,
      const SubtitleStyle().fontSize,
    );
  });

  test('approximate ASS background is measured by libass opaque box', () {
    final VideoComposeAssRenderer renderer = VideoComposeAssRenderer(
      VideoComposeFontService(),
    );
    final String ass = renderer.buildAssContent(
      width: 1280,
      height: 720,
      primary: <SubtitleItem>[
        SubtitleItem(
          index: 0,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          text: '测试 background',
        ),
      ],
      secondary: const <SubtitleItem>[],
      style: const SubtitleStyle(),
      alignment: const Alignment(0, 0.8),
    );
    expect(ass, contains('Style: Background'));
    expect(ass, contains(',3,0,0,5,'));
    expect(ass, contains(r'\xbord12.00'));
    expect(ass, contains(r'\ybord6.00'));
    expect(ass, isNot(contains(r'{\p1}')));
  });
}
