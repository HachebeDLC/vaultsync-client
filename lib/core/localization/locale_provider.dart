import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/vaultsync_launcher.dart';

final localeProvider = StateNotifierProvider<LocaleNotifier, Locale>((ref) {
  return LocaleNotifier(ref);
});

class LocaleNotifier extends StateNotifier<Locale> {
  final Ref _ref;
  LocaleNotifier(this._ref) : super(const Locale('en')) {
    _loadLocale();
  }

  static const String _key = 'selected_language';

  Future<void> _loadLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final langCode = prefs.getString(_key);
    if (langCode != null && mounted) {
      state = Locale(langCode);
      _syncNative(langCode);
    }
  }

  Future<void> setLocale(Locale locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, locale.languageCode);
    state = locale;
    _syncNative(locale.languageCode);
  }

  void _syncNative(String langCode) {
    _ref.read(vaultSyncLauncherProvider).setNativeLocale(langCode);
  }
}
