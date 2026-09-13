import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/subtitle_debug_preset.dart';

/// Global subtitle mode; the historical name is retained for integrations.
class SubtitleDebugSession extends ChangeNotifier {
  static const available = true;
  static const storageKey = 'globalSubtitlePresetMode.v1';
  static final instance = SubtitleDebugSession();
  SharedPreferences? _prefs;
  Future<void> _writes = Future<void>.value();
  bool _initialized = false;
  int _revision = 0;
  bool _enabled = false;
  bool _catalogVisible = true;
  String? _selectedId;
  final Map<String, SubtitleDebugPreset> _custom = {};
  String? saveError;
  // Retain navigation while the sidebar is closed.
  String browserCategory = '全部';
  String browserQuery = '';
  double browserOffset = 0;

  bool get enabled => _enabled;
  bool get catalogVisible => _enabled && _catalogVisible;
  SubtitleDebugPreset? get preset =>
      _enabled && _selectedId != null ? resolved(_selectedId!) : null;
  bool get usesPresets => preset != null;
  SubtitleDebugPreset resolved(String id) =>
      _custom[id] ?? subtitleDebugPresets.firstWhere((p) => p.id == id);

  Future<void> initialize([SharedPreferences? preferences]) async {
    if (_initialized) return;
    final revision = _revision;
    _prefs = preferences ?? await SharedPreferences.getInstance();
    _initialized = true;
    if (_revision != revision) return;
    try {
      final raw = _prefs!.getString(storageKey);
      if (raw == null) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      _enabled = data['enabled'] == true;
      _catalogVisible = data['catalogVisible'] != false;
      final id = data['selectedId'];
      _selectedId = subtitleDebugPresets.any((p) => p.id == id)
          ? id as String
          : null;
      final custom = data['custom'];
      if (custom is Map) {
        for (final value in custom.values) {
          final p = SubtitleDebugPreset.restore(value);
          if (p != null) _custom[p.id] = p;
        }
      }
      notifyListeners();
    } catch (_) {
      _enabled = false;
      _selectedId = null;
      _custom.clear();
    }
  }

  Future<void> _commit() {
    _revision++;
    final snapshot = jsonEncode({
      'enabled': _enabled,
      'catalogVisible': _catalogVisible,
      'selectedId': _selectedId,
      'custom': _custom.map((id, p) => MapEntry(id, p.toJson())),
    });
    notifyListeners();
    _writes = _writes.then((_) async {
      try {
        _prefs ??= await SharedPreferences.getInstance();
        if (!await _prefs!.setString(storageKey, snapshot)) {
          throw StateError('save failed');
        }
        if (saveError != null) {
          saveError = null;
          notifyListeners();
        }
      } catch (_) {
        saveError = '字幕设置未能保存，请重试';
        notifyListeners();
      }
    });
    return _writes;
  }

  Future<void> toggle() {
    _enabled = !_enabled;
    if (_enabled) _catalogVisible = true;
    return _commit();
  }

  Future<void> select(SubtitleDebugPreset? preset) {
    if (!_enabled) return Future<void>.value();
    _selectedId = preset?.id;
    return _commit();
  }

  Future<void> useOriginal() {
    _selectedId = null;
    _catalogVisible = false;
    return _commit();
  }

  Future<void> openCatalog() {
    _catalogVisible = true;
    return _commit();
  }

  Future<void> updatePreset(SubtitleDebugPreset preset) {
    _custom[preset.id] = preset;
    return _commit();
  }

  Future<void> resetPreset(String id) {
    _custom.remove(id);
    return _commit();
  }

  Future<void> close() {
    _enabled = false;
    return _commit();
  }

  Future<void> flush() => _writes;
  @visibleForTesting
  void resetForTest() {
    browserCategory = '全部';
    browserQuery = '';
    browserOffset = 0;
    _writes = Future<void>.value();
    _prefs = null;
    _initialized = false;
    _revision++;
    _enabled = false;
    _catalogVisible = true;
    _selectedId = null;
    _custom.clear();
    saveError = null;
  }
}
