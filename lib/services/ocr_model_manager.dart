import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/ocr_subtitle_models.dart';
import 'settings_service.dart';

class OcrModelFiles {
  final String detection;
  final String recognition;
  final String dictionary;

  const OcrModelFiles({
    required this.detection,
    required this.recognition,
    required this.dictionary,
  });
}

class _BundledModelFile {
  final String name;
  final String sha256;

  const _BundledModelFile(this.name, this.sha256);

  String get assetPath => 'assets/models/ocr/$name';
}

/// Materializes the selected bundled OCR models into the app's large-data
/// directory. All model payloads ship with the application, so OCR never
/// depends on network access and a partial copy can always be recreated.
class OcrModelManager {
  static const _det = _BundledModelFile(
    'ch_PP-OCRv4_det_mobile.onnx',
    'd2a7720d45a54257208b1e13e36a8479894cb74155a5efe29462512d42f49da9',
  );

  static const Map<OcrSubtitleLanguage, _BundledModelFile> _recognizers = {
    OcrSubtitleLanguage.chinese: _BundledModelFile(
      'ch_PP-OCRv4_rec_mobile.onnx',
      '48fc40f24f6d2a207a2b1091d3437eb3cc3eb6b676dc3ef9c37384005483683b',
    ),
    OcrSubtitleLanguage.english: _BundledModelFile(
      'en_PP-OCRv4_rec_mobile.onnx',
      'e8770c967605983d1570cdf5352041dfb68fa0c21664f49f47b155abd3e0e318',
    ),
    OcrSubtitleLanguage.japanese: _BundledModelFile(
      'japan_PP-OCRv4_rec_mobile.onnx',
      'e1075a67dba758ecfc7ebc78a10ae61c95ac8fb66a9c86fab5541e33f085cb7a',
    ),
    OcrSubtitleLanguage.korean: _BundledModelFile(
      'korean_PP-OCRv4_rec_mobile.onnx',
      'ab151ba9065eccd98f884cf4d927db091be86137276392072edd4f9d43ad7426',
    ),
    OcrSubtitleLanguage.latin: _BundledModelFile(
      'latin_PP-OCRv3_rec_mobile.onnx',
      'e9d7a33667e8aaa702862975186adf2012e3f390cc0f9422865957125f8071cf',
    ),
  };

  static const Map<OcrSubtitleLanguage, _BundledModelFile> _dictionaries = {
    OcrSubtitleLanguage.chinese: _BundledModelFile(
      'ppocr_keys_v1.txt',
      'a1c84d9bdb9ab29043c58896224d32941783eb821629618416dcb08f12886492',
    ),
    OcrSubtitleLanguage.english: _BundledModelFile(
      'en_dict.txt',
      'e1f9b09d757e60b89b6c5c701b40e4da62e44f9ff556b73959c50edda12cd530',
    ),
    OcrSubtitleLanguage.japanese: _BundledModelFile(
      'japan_dict.txt',
      '1dcfcb41eec90576a945b3084f22ade11ced506e24f14879245b071698f308e8',
    ),
    OcrSubtitleLanguage.korean: _BundledModelFile(
      'korean_dict.txt',
      'aa1fdc8ae8f7cd40a0ec4edb472eb0421e11427e6ccfee9915440742c18b0a20',
    ),
    OcrSubtitleLanguage.latin: _BundledModelFile(
      'latin_dict.txt',
      '8e6d4e3629788c35c31f7e530287d6147b549bb7a265bd6708bb281134429e2c',
    ),
  };

  final Directory? rootOverride;

  const OcrModelManager({this.rootOverride});

  bool isBundled(OcrSubtitleLanguage language) => true;

  int bundledModelCountFor(OcrSubtitleLanguage language) => 2;

  int get totalBundledOnnxModelCount => 1 + _recognizers.length;

  Future<Directory> modelDirectory({bool create = false}) async {
    final root =
        rootOverride ?? await SettingsService().resolveLargeDataRootDir();
    final dir = Directory(p.join(root.path, 'ocr_models', 'ppocr_v4_mobile'));
    if (create && !await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<bool> isInstalled(OcrSubtitleLanguage language) async {
    final dir = await modelDirectory();
    for (final spec in [
      _det,
      _recognizers[language]!,
      _dictionaries[language]!,
    ]) {
      final file = File(p.join(dir.path, spec.name));
      if (!await file.exists() || !await _matchesHash(file, spec.sha256)) {
        return false;
      }
    }
    return true;
  }

  Future<OcrModelFiles> ensureInstalled(
    OcrSubtitleLanguage language, {
    void Function(double progress, String message)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = await modelDirectory(create: true);
    final specs = [_det, _recognizers[language]!, _dictionaries[language]!];
    for (var index = 0; index < specs.length; index++) {
      if (isCancelled?.call() ?? false) throw const OcrDownloadCancelled();
      final spec = specs[index];
      await _materializeBundled(dir, spec, isCancelled: isCancelled);
      onProgress?.call(
        (index + 1) / specs.length,
        '正在校验内置 ${language.label} OCR 模型 ${index + 1}/${specs.length}',
      );
    }

    // Remove the obsolete orientation classifier downloaded by older builds.
    final obsolete = File(
      p.join(dir.path, 'ch_ppocr_mobile_v2.0_cls_mobile.onnx'),
    );
    if (await obsolete.exists()) await obsolete.delete();

    return OcrModelFiles(
      detection: p.join(dir.path, _det.name),
      recognition: p.join(dir.path, _recognizers[language]!.name),
      dictionary: p.join(dir.path, _dictionaries[language]!.name),
    );
  }

  Future<void> deleteLanguage(OcrSubtitleLanguage language) async {
    final dir = await modelDirectory();
    for (final spec in [_recognizers[language]!, _dictionaries[language]!]) {
      final file = File(p.join(dir.path, spec.name));
      if (await file.exists()) await file.delete();
      final partial = File('${file.path}.partial');
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _materializeBundled(
    Directory dir,
    _BundledModelFile spec, {
    bool Function()? isCancelled,
  }) async {
    final target = File(p.join(dir.path, spec.name));
    if (await target.exists() && await _matchesHash(target, spec.sha256)) {
      return;
    }
    if (await target.exists()) await target.delete();
    final partial = File('${target.path}.partial');
    if (await partial.exists()) await partial.delete();
    if (isCancelled?.call() ?? false) throw const OcrDownloadCancelled();

    final data = await rootBundle.load(spec.assetPath);
    if (isCancelled?.call() ?? false) throw const OcrDownloadCancelled();
    await partial.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    if (!await _matchesHash(partial, spec.sha256)) {
      await partial.delete();
      throw StateError('内置 OCR 模型校验失败：${spec.name}');
    }
    await partial.rename(target.path);
  }

  Future<bool> _matchesHash(File file, String expected) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase() == expected.toLowerCase();
  }
}

class OcrDownloadCancelled implements Exception {
  const OcrDownloadCancelled();
}
