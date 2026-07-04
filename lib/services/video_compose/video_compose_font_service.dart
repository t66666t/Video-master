import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/subtitle_style.dart';

class VideoComposeFontService {
  static const Set<String> bundledFontFamilies = <String>{
    'OPPO Sans 4.0',
    '方正黑体',
    'MiSans',
    'Noto Serif CJK SC',
    'Swei Gothic CJK SC',
    '方正楷体',
    'Comic Relief',
    'Roboto',
  };

  static const List<String> _bundledFontAssetPaths = <String>[
    'assets/fonts/OPPO Sans 4.0.ttf',
    'assets/fonts/方正黑体 简体中文.TTF',
    'assets/fonts/方正楷体 简体中文.ttf',
    'assets/fonts/NotoSerifCJKsc-Bold.otf',
    'assets/fonts/SweiGothicCJKsc-Bold.ttf',
    'assets/fonts/ComicRelief-Regular.ttf',
    'assets/fonts/ComicRelief-Bold.ttf',
    'assets/fonts/MiSans-Thin.otf',
    'assets/fonts/MiSans-ExtraLight.otf',
    'assets/fonts/MiSans-Light.otf',
    'assets/fonts/MiSans-Regular.otf',
    'assets/fonts/MiSans-Normal.otf',
    'assets/fonts/MiSans-Medium.otf',
    'assets/fonts/MiSans-Semibold.otf',
    'assets/fonts/MiSans-Demibold.otf',
    'assets/fonts/MiSans-Bold.otf',
    'assets/fonts/MiSans-Heavy.otf',
    'assets/fonts/Roboto_Condensed-Thin.ttf',
    'assets/fonts/Roboto_Condensed-ExtraLight.ttf',
    'assets/fonts/Roboto_Condensed-Light.ttf',
    'assets/fonts/Roboto_Condensed-Regular.ttf',
    'assets/fonts/Roboto_Condensed-Medium.ttf',
    'assets/fonts/Roboto_Condensed-SemiBold.ttf',
    'assets/fonts/Roboto_Condensed-Bold.ttf',
    'assets/fonts/Roboto_Condensed-ExtraBold.ttf',
    'assets/fonts/Roboto_Condensed-Black.ttf',
  ];

  String? _mobileFontsDirCache;

  bool requiresBundledFonts(SubtitleStyle style) {
    return bundledFontFamilies.contains(style.fontFamilyChinese) ||
        bundledFontFamilies.contains(style.fontFamilyEnglish);
  }

  Future<String?> resolveAssFontsDir() async {
    if (Platform.isWindows || Platform.isMacOS) {
      return _resolveBundledFontsDir();
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return _prepareMobileFontsDir();
    }
    return null;
  }

  Future<void> configureForRender({String? fontsDir}) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final List<String> fontDirs = <String>[];
    if (fontsDir != null) {
      fontDirs.add(fontsDir);
    }
    if (Platform.isAndroid) {
      fontDirs.add('/system/fonts');
    }
    if (Platform.isIOS) {
      fontDirs.add('/System/Library/Fonts');
    }
    if (fontDirs.isEmpty) return;
    final Map<String, String> fontNameMap = mobileFontNameMap();
    await FFmpegKitConfig.setFontDirectoryList(
      fontDirs,
      fontNameMap.isEmpty ? null : fontNameMap,
    );
    if (fontsDir != null) {
      await FFmpegKitConfig.setFontDirectory(
        fontsDir,
        fontNameMap.isEmpty ? null : fontNameMap,
      );
    }
  }

  String resolveSystemFont(String familyName) {
    switch (familyName) {
      case 'OPPO Sans 4.0':
        return 'OPPO Sans 4.0';
      case '方正黑体':
        return '方正黑体简体';
      case '方正楷体':
        return '方正楷体简体';
      case 'Swei Gothic CJK SC':
        return '獅尾圓體SC-Bold';
      case 'Noto Serif CJK SC':
        return 'Noto Serif CJK SC';
      case 'Comic Relief':
        return 'Comic Relief';
      case 'MiSans':
        return 'MiSans';
      case 'Roboto':
        return 'Roboto Condensed Condensed';
    }

    if (Platform.isAndroid || Platform.isIOS) {
      switch (familyName) {
        case 'Sans Serif':
        case 'System':
          return 'sans-serif';
        case 'Serif':
          return 'serif';
        case 'Monospace':
          return 'monospace';
        case 'Cursive':
          return 'cursive';
        default:
          return familyName;
      }
    }

    switch (familyName) {
      case 'Sans Serif':
      case 'System':
        return 'Arial';
      case 'Serif':
        return 'Times New Roman';
      case 'Monospace':
        return 'Courier New';
      case 'Cursive':
        return 'Comic Sans MS';
      default:
        return familyName;
    }
  }

  Map<String, String> mobileFontNameMap() {
    return <String, String>{
      'OPPO Sans 4.0.ttf': 'OPPO Sans 4.0',
      '方正黑体 简体中文.TTF': '方正黑体简体',
      '方正楷体 简体中文.ttf': '方正楷体简体',
      'NotoSerifCJKsc-Bold.otf': 'Noto Serif CJK SC',
      'SweiGothicCJKsc-Bold.ttf': '獅尾圓體SC-Bold',
      'ComicRelief-Regular.ttf': 'Comic Relief',
      'ComicRelief-Bold.ttf': 'Comic Relief',
      'MiSans-Thin.otf': 'MiSans',
      'MiSans-ExtraLight.otf': 'MiSans',
      'MiSans-Light.otf': 'MiSans',
      'MiSans-Regular.otf': 'MiSans',
      'MiSans-Normal.otf': 'MiSans',
      'MiSans-Medium.otf': 'MiSans',
      'MiSans-Semibold.otf': 'MiSans',
      'MiSans-Demibold.otf': 'MiSans',
      'MiSans-Bold.otf': 'MiSans',
      'MiSans-Heavy.otf': 'MiSans',
      'Roboto_Condensed-Thin.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-ExtraLight.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-Light.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-Regular.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-Medium.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-SemiBold.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-Bold.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-ExtraBold.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-Black.ttf': 'Roboto Condensed Condensed',
    };
  }

  Future<String?> _prepareMobileFontsDir() async {
    if (_mobileFontsDirCache != null &&
        Directory(_mobileFontsDirCache!).existsSync()) {
      return _mobileFontsDirCache;
    }
    try {
      final List<String> discoveredAssets = await _collectBundledFontAssets();
      final Set<String> fontAssets = <String>{
        ..._bundledFontAssetPaths,
        ...discoveredAssets,
      };
      if (fontAssets.isEmpty) return null;
      final Directory tempDir = await getTemporaryDirectory();
      final Directory fontsDir = Directory(p.join(tempDir.path, 'compose_fonts'));
      if (!await fontsDir.exists()) {
        await fontsDir.create(recursive: true);
      }
      int copiedCount = 0;
      for (final String assetPath in fontAssets) {
        try {
          final ByteData data = await rootBundle.load(assetPath);
          final String fileName = p.basename(assetPath);
          final File file = File(p.join(fontsDir.path, fileName));
          await file.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true,
          );
          copiedCount++;
        } catch (_) {}
      }
      if (copiedCount == 0) {
        return null;
      }
      _mobileFontsDirCache = fontsDir.path;
      return _mobileFontsDirCache;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _collectBundledFontAssets() async {
    final Set<String> assets = <String>{};
    try {
      final String fontManifestContent =
          await rootBundle.loadString('FontManifest.json');
      final dynamic decoded = jsonDecode(fontManifestContent);
      if (decoded is List) {
        for (final dynamic familyNode in decoded) {
          if (familyNode is! Map) continue;
          final dynamic fonts = familyNode['fonts'];
          if (fonts is! List) continue;
          for (final dynamic fontNode in fonts) {
            if (fontNode is! Map) continue;
            final String? asset = fontNode['asset']?.toString();
            if (asset != null && _isFontAssetPath(asset)) {
              assets.add(asset);
            }
          }
        }
      }
    } catch (_) {}
    if (assets.isNotEmpty) {
      final List<String> list = assets.toList()..sort();
      return list;
    }
    try {
      final String assetManifestContent =
          await rootBundle.loadString('AssetManifest.json');
      final dynamic decoded = jsonDecode(assetManifestContent);
      if (decoded is Map) {
        for (final dynamic key in decoded.keys) {
          final String path = key.toString();
          if (_isFontAssetPath(path)) {
            assets.add(path);
          }
        }
      } else if (decoded is List) {
        for (final dynamic node in decoded) {
          if (node is Map && node['asset'] != null) {
            final String path = node['asset'].toString();
            if (_isFontAssetPath(path)) {
              assets.add(path);
            }
          } else if (node is String && _isFontAssetPath(node)) {
            assets.add(node);
          }
        }
      }
    } catch (_) {}
    final List<String> list = assets.toList()..sort();
    return list;
  }

  bool _isFontAssetPath(String path) {
    final String lower = path.toLowerCase();
    return lower.startsWith('assets/fonts/') &&
        (lower.endsWith('.ttf') ||
            lower.endsWith('.otf') ||
            lower.endsWith('.ttc'));
  }

  String? _resolveBundledFontsDir() {
    if (!(Platform.isWindows || Platform.isMacOS)) return null;
    final Directory exeDir = File(Platform.resolvedExecutable).parent;
    final String candidate = p.join(
      exeDir.path,
      'data',
      'flutter_assets',
      'assets',
      'fonts',
    );
    final Directory packagedDir = Directory(candidate);
    if (packagedDir.existsSync()) {
      return packagedDir.path;
    }
    final Directory devDir =
        Directory(p.join(Directory.current.path, 'assets', 'fonts'));
    if (devDir.existsSync()) {
      return devDir.path;
    }
    return null;
  }
}
