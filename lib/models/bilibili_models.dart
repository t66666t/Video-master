class BilibiliVideoInfo {
  final String title;
  final String desc;
  final String pic;
  final String bvid;
  final String aid; // Add aid
  final String ownerName;
  final String ownerMid;
  final int pubDate;
  final List<BilibiliPage> pages;
  
  // Optional Collection/Season Info (Level 1)
  final BilibiliCollectionInfo? collectionInfo; 

  BilibiliVideoInfo({
    required this.title,
    required this.desc,
    required this.pic,
    required this.bvid,
    required this.aid,
    required this.ownerName,
    required this.ownerMid,
    required this.pubDate,
    required this.pages,
    this.collectionInfo,
  });

  factory BilibiliVideoInfo.fromJson(Map<String, dynamic> json) {
    // Check if this is a local storage map (has 'pages' as list directly, not inside data)
    if (json.containsKey('title') && json.containsKey('pages') && !json.containsKey('data')) {
      return BilibiliVideoInfo.fromMap(json);
    }

    final data = json['data'];
    
    // Check for UGC Season (Collection)
    BilibiliCollectionInfo? collectionInfo;
    final ugcSeason = data['ugc_season'];
    
    if (ugcSeason != null && ugcSeason['sections'] != null) {
       final sections = ugcSeason['sections'] as List;
       final List<BilibiliVideoInfo> videos = [];
       
       for (var section in sections) {
         final episodes = section['episodes'] as List?;
         if (episodes != null) {
           for (var ep in episodes) {
             // Each episode in a season is conceptually a VIDEO (Level 2)
             // It might have its own pages (Level 3), but usually season list gives just the main page.
             // We construct a 'VideoInfo' for each item.
             // Fix for multi-page parsing: Check if 'pages' exist in episode, otherwise use episode itself
             List<BilibiliPage> videoPages = [];
             if (ep['pages'] != null) {
                videoPages = (ep['pages'] as List).map((p) => BilibiliPage(
                   cid: p['cid'] ?? 0,
                   page: p['page'] ?? 1,
                   part: p['part'] ?? '',
                   duration: p['duration'] ?? 0,
                   bvid: ep['bvid'],
                   aid: ep['aid']?.toString(),
                )).toList();
             } else {
                // Fallback to single page
                videoPages = [
                   BilibiliPage(
                     cid: ep['cid'] ?? 0,
                     page: 1, 
                     part: ep['title'] ?? '',
                     duration: ep['duration'] ?? 0,
                     bvid: ep['bvid'],
                     aid: ep['aid']?.toString(),
                   )
                ];
             }

             videos.add(BilibiliVideoInfo(
               title: ep['title'] ?? '',
               desc: '',
               pic: ep['arc']?['pic'] ?? data['pic'] ?? '', // Use arc pic or season pic
               bvid: ep['bvid'] ?? '',
               aid: ep['aid']?.toString() ?? '',
               ownerName: data['owner']['name'] ?? '',
               ownerMid: data['owner']['mid'].toString(),
               pubDate: ep['arc']?['pubdate'] ?? 0,
               pages: videoPages,
             ));
           }
         }
       }
       
       collectionInfo = BilibiliCollectionInfo(
         title: ugcSeason['title'] ?? data['title'],
         cover: ugcSeason['cover'] ?? data['pic'],
         videos: videos,
       );
    }
    
    // Standard Pages (for Single Video)
    List<BilibiliPage> standardPages = [];
    if (data['pages'] != null) {
       standardPages = (data['pages'] as List)
              .map((e) => BilibiliPage.fromJson(e))
              .toList();
    }

    return BilibiliVideoInfo(
      title: data['title'] ?? '',
      desc: data['desc'] ?? '',
      pic: data['pic'] ?? '',
      bvid: data['bvid'] ?? '',
      aid: data['aid']?.toString() ?? '',
      ownerName: data['owner']['name'] ?? '',
      ownerMid: data['owner']['mid'].toString(),
      pubDate: data['pubdate'] ?? 0,
      pages: standardPages,
      collectionInfo: collectionInfo,
    );
  }

  factory BilibiliVideoInfo.fromMap(Map<String, dynamic> map) {
    return BilibiliVideoInfo(
      title: map['title'] ?? '',
      desc: map['desc'] ?? '',
      pic: map['pic'] ?? '',
      bvid: map['bvid'] ?? '',
      aid: map['aid'] ?? '',
      ownerName: map['ownerName'] ?? '',
      ownerMid: map['ownerMid'] ?? '',
      pubDate: map['pubDate'] ?? 0,
      pages: (map['pages'] as List?)?.map((e) => BilibiliPage.fromJson(e)).toList() ?? [],
      collectionInfo: map['collectionInfo'] != null ? BilibiliCollectionInfo.fromMap(map['collectionInfo']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'desc': desc,
      'pic': pic,
      'bvid': bvid,
      'aid': aid,
      'ownerName': ownerName,
      'ownerMid': ownerMid,
      'pubDate': pubDate,
      'pages': pages.map((e) => e.toJson()).toList(),
      'collectionInfo': collectionInfo?.toJson(),
    };
  }
}

class BilibiliCollectionInfo {
  final String title;
  final String cover;
  final List<BilibiliVideoInfo> videos;

  BilibiliCollectionInfo({
    required this.title,
    required this.cover,
    required this.videos,
  });

  factory BilibiliCollectionInfo.fromMap(Map<String, dynamic> map) {
    return BilibiliCollectionInfo(
      title: map['title'] ?? '',
      cover: map['cover'] ?? '',
      videos: (map['videos'] as List?)?.map((e) => BilibiliVideoInfo.fromMap(e)).toList() ?? [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'cover': cover,
      'videos': videos.map((e) => e.toJson()).toList(),
    };
  }
}

class BilibiliPage {
  final int cid;
  final int page;
  final String part;
  final int duration;
  final String? bvid; // Optional specific bvid (for collection/season)
  final String? aid; // Optional specific aid

  BilibiliPage({
    required this.cid,
    required this.page,
    required this.part,
    required this.duration,
    this.bvid,
    this.aid,
  });

  factory BilibiliPage.fromJson(Map<String, dynamic> json) {
    return BilibiliPage(
      cid: json['cid'] ?? 0,
      page: json['page'] ?? 1,
      part: json['part'] ?? '',
      duration: json['duration'] ?? 0,
      bvid: json['bvid'],
      aid: json['aid']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'cid': cid,
      'page': page,
      'part': part,
      'duration': duration,
      'bvid': bvid,
      'aid': aid,
    };
  }
}

class BilibiliStreamInfo {
  final List<StreamItem> videoStreams;
  final List<StreamItem> audioStreams;
  final Map<int, String> qualityMap;

  BilibiliStreamInfo({
    required this.videoStreams,
    required this.audioStreams,
    required this.qualityMap,
  });

  factory BilibiliStreamInfo.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    if (data == null) {
      return BilibiliStreamInfo(videoStreams: [], audioStreams: [], qualityMap: {});
    }

    final dash = data['dash'];
    if (dash == null) {
      return BilibiliStreamInfo(videoStreams: [], audioStreams: [], qualityMap: {});
    }

    // Default fallback map (based on BBDown constants)
    final Map<int, String> qMap = {
      127: "8K 超高清",
      126: "杜比视界",
      125: "HDR 真彩",
      120: "4K 超清",
      116: "1080P 60帧",
      112: "1080P 高码率",
      80: "1080P 高清",
      74: "720P 60帧",
      64: "720P 高清",
      32: "480P 清晰",
      16: "360P 流畅",
    };

    // Override with dynamic values from API if available
    final acceptQuality = data['accept_quality'] as List?;
    final acceptDesc = data['accept_description'] as List?;
    
    if (acceptQuality != null && acceptDesc != null && acceptQuality.length == acceptDesc.length) {
      for (int i = 0; i < acceptQuality.length; i++) {
        final q = acceptQuality[i];
        final d = acceptDesc[i];
        if (q is int && d is String) {
          qMap[q] = d;
        }
      }
    }

    final videos = (dash['video'] as List?)
            ?.map((e) => StreamItem.fromJson(e, qMap[e['id'] as int]))
            .toList() ??
        [];
    final audios = (dash['audio'] as List?)
            ?.map((e) => StreamItem.fromJson(e))
            .toList() ??
        [];

    // Sort by bandwidth (quality) descending
    videos.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    audios.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));

    return BilibiliStreamInfo(
      videoStreams: videos,
      audioStreams: audios,
      qualityMap: qMap,
    );
  }
}

class StreamItem {
  final int id;
  final String baseUrl;
  final int bandwidth;
  final String codecs;
  final int codecid;
  final String? qualityName;

  StreamItem({
    required this.id,
    required this.baseUrl,
    required this.bandwidth,
    required this.codecs,
    required this.codecid,
    this.qualityName,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'base_url': baseUrl,
      'bandwidth': bandwidth,
      'codecs': codecs,
      'codecid': codecid,
      'qualityName': qualityName,
    };
  }

  factory StreamItem.fromJson(Map<String, dynamic> json, [String? qualityName]) {
    return StreamItem(
      id: json['id'] ?? 0,
      baseUrl: json['base_url'] ?? '',
      bandwidth: json['bandwidth'] ?? 0,
      codecs: json['codecs'] ?? '',
      codecid: json['codecid'] ?? 0,
      qualityName: qualityName ?? json['qualityName'],
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamItem &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          codecid == other.codecid &&
          codecs == other.codecs;

  @override
  int get hashCode => id.hashCode ^ codecid.hashCode ^ codecs.hashCode;
}
