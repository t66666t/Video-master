import 'bilibili_api_service.dart';
import 'bilibili_download_service.dart';
import 'bilibili_interaction_gate.dart';

/// One of the user's own favourite folders, with whether it holds the video.
class BilibiliFavoriteFolder {
  final int id;
  final String title;
  final int mediaCount;
  final bool containsVideo;

  const BilibiliFavoriteFolder({
    required this.id,
    required this.title,
    this.mediaCount = 0,
    this.containsVideo = false,
  });
}

/// Like / coin / favourite / follow for the video detail page.
///
/// State reads are GETs with the login cookies (never the cookie-free public
/// client) and are not affected by read-only mode. Every write goes through
/// [BilibiliInteractionGate.post].
class BilibiliVideoActions {
  BilibiliVideoActions({
    required Future<Object?> Function(Uri endpoint) readData,
    required this.gate,
    required Future<bool> Function() hasLogin,
    required Future<int> Function() accountMid,
  }) : _readData = readData,
       _hasLogin = hasLogin,
       _accountMid = accountMid;

  factory BilibiliVideoActions.forService(BilibiliDownloadService service) {
    final api = service.apiService;
    return BilibiliVideoActions(
      readData: api.fetchAccountData,
      gate: service.interactionGate,
      hasLogin: () async {
        await api.init();
        return api.hasCookie();
      },
      accountMid: () async => (await api.fetchLoginState()).account?.mid ?? 0,
    );
  }

  /// Most coins one account may give an original video.
  static const int maxCoins = 2;

  /// Most coins for a reprint (`copyright == 2`).
  static const int maxCoinsReprint = 1;

  static const String _host = 'api.bilibili.com';

  final Future<Object?> Function(Uri endpoint) _readData;
  final BilibiliInteractionGate gate;
  final Future<bool> Function() _hasLogin;
  final Future<int> Function() _accountMid;

  /// A login is stored (it may still turn out expired).
  Future<bool> hasLogin() async {
    try {
      return await _hasLogin();
    } catch (_) {
      return false;
    }
  }

  /// Coin cap for a video: 1 for a reprint (`copyright == 2`), otherwise 2.
  /// An unknown copyright counts as original; Bilibili still refuses a
  /// second coin on a reprint.
  static int coinLimit(int copyright) =>
      copyright == 2 ? maxCoinsReprint : maxCoins;

  /// Coins still allowed: the cap for [copyright] minus what was given.
  static int coinsLeft(int? given, {int copyright = 0}) {
    final left = coinLimit(copyright) - (given ?? 0);
    return left < 0 ? 0 : left;
  }

  // ------------------------------------------------------------------ reads

  Future<bool> fetchLiked(String bvid) async {
    final data = await _readData(
      Uri.https(_host, '/x/web-interface/archive/has/like', {'bvid': bvid}),
    );
    return _readBool(data is Map ? data['like'] ?? data['data'] : data);
  }

  Future<int> fetchCoins(String bvid) async {
    final data = await _readData(
      Uri.https(_host, '/x/web-interface/archive/coins', {'bvid': bvid}),
    );
    final given = data is Map ? _readInt(data['multiply']) : 0;
    return given.clamp(0, maxCoins);
  }

  Future<bool> fetchFavorited(int aid) async {
    final data = await _readData(
      Uri.https(_host, '/x/v2/fav/video/favoured', {'aid': '$aid'}),
    );
    if (data is! Map) return false;
    return _readBool(data['favoured']) || _readInt(data['count']) > 0;
  }

  /// Following includes a quiet follow (1) and mutual follow (6).
  Future<bool> fetchFollowing(int mid) async {
    final data = await _readData(
      Uri.https(_host, '/x/relation', {'fid': '$mid'}),
    );
    if (data is! Map) return false;
    final attribute = _readInt(data['attribute']);
    return attribute == 1 || attribute == 2 || attribute == 6;
  }

  /// The user's own folders and whether each holds the video [aid].
  Future<List<BilibiliFavoriteFolder>> fetchFavoriteFolders(int aid) async {
    final mid = await _accountMid();
    if (mid <= 0) {
      throw const BilibiliAccountReadException('无法确认当前登录账号');
    }
    final data = await _readData(
      Uri.https(_host, '/x/v3/fav/folder/created/list-all', {
        'up_mid': '$mid',
        'type': '2',
        'rid': '$aid',
      }),
    );
    final list = data is Map ? data['list'] : null;
    if (list is! List) return const <BilibiliFavoriteFolder>[];
    return <BilibiliFavoriteFolder>[
      for (final raw in list)
        if (raw is Map && _readInt(raw['id']) > 0)
          BilibiliFavoriteFolder(
            id: _readInt(raw['id']),
            title: (raw['title'] ?? '').toString().trim().isEmpty
                ? '未命名收藏夹'
                : raw['title'].toString().trim(),
            mediaCount: _readInt(raw['media_count']),
            containsVideo: _readBool(raw['fav_state']),
          ),
    ];
  }

  // ----------------------------------------------------------------- writes
  //
  // Parameters are checked at run time (not with asserts, which release
  // builds drop). A bad value returns [BilibiliWriteOutcome.invalidRequest]
  // without touching the network.

  static BilibiliWriteResult _invalid(String message) => BilibiliWriteResult(
    BilibiliWriteOutcome.invalidRequest,
    message: message,
  );

  static const String _badVideo = '视频信息不完整，操作未发送';

  Future<BilibiliWriteResult> setLiked({
    required int aid,
    required bool liked,
  }) async {
    if (aid <= 0) return _invalid(_badVideo);
    return gate.post(
      Uri.https(_host, '/x/web-interface/archive/like'),
      form: {'aid': '$aid', 'like': liked ? '1' : '2'},
    );
  }

  /// Gives [count] coins. Coins cannot be taken back; the page asks for an
  /// explicit confirmation before calling this.
  ///
  /// [count] must be within 1..(cap for [copyright] − [alreadyGiven]);
  /// anything else returns a failed result and sends nothing.
  Future<BilibiliWriteResult> addCoins({
    required int aid,
    required int count,
    bool alsoLike = false,
    int copyright = 0,
    int alreadyGiven = 0,
  }) async {
    if (aid <= 0) return _invalid(_badVideo);
    final left = coinsLeft(alreadyGiven, copyright: copyright);
    if (left <= 0) {
      return _invalid('这个视频最多投 ${coinLimit(copyright)} 枚硬币，已经投满了');
    }
    if (count < 1 || count > left) {
      return _invalid('投币数量不正确（这次最多 $left 枚），操作未发送');
    }
    return gate.post(
      Uri.https(_host, '/x/web-interface/coin/add'),
      form: {
        'aid': '$aid',
        'multiply': '$count',
        'select_like': alsoLike ? '1' : '0',
      },
    );
  }

  /// Sends only the folders that changed between [before] and [after].
  /// Returns null, without any request, when nothing changed.
  Future<BilibiliWriteResult?> updateFavorites({
    required int aid,
    required Set<int> before,
    required Set<int> after,
  }) async {
    final added = after.difference(before);
    final removed = before.difference(after);
    if (added.isEmpty && removed.isEmpty) return null;
    if (aid <= 0) return _invalid(_badVideo);
    if (added.any((id) => id <= 0) || removed.any((id) => id <= 0)) {
      return _invalid('收藏夹信息不正确，操作未发送');
    }
    return gate.post(
      Uri.https(_host, '/x/v3/fav/resource/deal'),
      form: {
        'rid': '$aid',
        'type': '2',
        'add_media_ids': added.join(','),
        'del_media_ids': removed.join(','),
      },
    );
  }

  Future<BilibiliWriteResult> setFollowing({
    required int mid,
    required bool following,
  }) async {
    if (mid <= 0) return _invalid('UP 主信息不完整，操作未发送');
    return gate.post(
      Uri.https(_host, '/x/relation/modify'),
      form: {'fid': '$mid', 'act': following ? '1' : '2', 're_src': '11'},
    );
  }

  static int _readInt(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}'.trim()) ?? 0;
  }

  static bool _readBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = '${value ?? ''}'.trim().toLowerCase();
    return text == 'true' || text == '1';
  }
}
