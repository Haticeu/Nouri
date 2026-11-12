/// App language: the device's language when we support it (Turkish), else
/// English. No in-app setting.
///
/// UI strings are written in English in the code and wrapped in `t(...)`;
/// `{0}`, `{1}` are placeholders filled from `args`. Text that comes from
/// the server in English (notifications, change history, consent, errors)
/// goes through [tServer].
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'i18n_tr.dart';

String appLang = 'en';

const supportedLocales = [Locale('en'), Locale('tr')];

Future<void> initI18n() async {
  final device = PlatformDispatcher.instance.locale.languageCode;
  appLang = device == 'tr' ? 'tr' : 'en';
  Intl.defaultLocale = appLang == 'tr' ? 'tr_TR' : 'en_US';
  await initializeDateFormatting(Intl.defaultLocale);
}

/// Translate a UI string. `t('{0} kcal', [420])`
String t(String en, [List<Object?> args = const []]) {
  var s = appLang == 'tr' ? (trStrings[en] ?? en) : en;
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i] ?? ''}');
  }
  return s;
}

/// Translate an English sentence produced by the server.
String tServer(String? text) {
  if (text == null || appLang == 'en') return text ?? '';
  final exact = trStrings[text];
  if (exact != null) return exact;
  for (final (pattern, replacement) in trServerPatterns) {
    final m = pattern.firstMatch(text);
    if (m != null) {
      var out = replacement;
      for (var i = 1; i <= m.groupCount; i++) {
        out = out.replaceAll('\$$i', trStrings[m.group(i)] ?? m.group(i) ?? '');
      }
      return out;
    }
  }
  return text;
}
