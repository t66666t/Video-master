import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';

void main() {
  group('Bilibili login status classification', () {
    test('recognizes an explicitly logged-in response', () {
      final status = BilibiliApiService.classifyLoginResponse(
        statusCode: 200,
        responseData: {
          'code': 0,
          'data': {'isLogin': true},
        },
      );

      expect(status, BilibiliLoginStatus.loggedIn);
    });

    test('recognizes an explicit logged-out response', () {
      final status = BilibiliApiService.classifyLoginResponse(
        statusCode: 200,
        responseData: {
          'code': 0,
          'data': {'isLogin': false},
        },
      );

      expect(status, BilibiliLoginStatus.loggedOut);
    });

    test('does not misclassify an unavailable response as logged out', () {
      expect(
        BilibiliApiService.classifyLoginResponse(
          statusCode: null,
          responseData: null,
        ),
        BilibiliLoginStatus.unavailable,
      );
      expect(
        BilibiliApiService.classifyLoginResponse(
          statusCode: 200,
          responseData: {'code': -1},
        ),
        BilibiliLoginStatus.unavailable,
      );
    });
  });
}
