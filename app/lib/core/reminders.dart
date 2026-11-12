import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'session.dart';
import 'ui.dart';
import 'i18n.dart';

/// Meal reminders ("What did you have for lunch?") as local notifications.
///
/// Times live in `reminder_settings` (defaults set by the database at signup).
/// We schedule one notification per meal for the next 7 days and skip today's
/// reminder for a meal that is already logged. Rescheduled whenever the app
/// opens, settings change or a meal is logged. Not available on the web.
class Reminders {
  Reminders._();

  static const meals = ['breakfast', 'lunch', 'dinner'];
  static const _baseId = 1000;
  static const _days = 7;

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static bool get supported => !kIsWeb;

  static Future<void> _init() async {
    if (_ready || !supported) return;
    tzdata.initializeTimeZones();
    try {
      final local = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(local.identifier));
    } catch (_) {
      // Fall back to UTC if the device zone is unknown to the tz database.
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    _ready = true;
  }

  /// Ask the OS for notification permission (Android 13+, iOS).
  static Future<void> requestPermission() async {
    if (!supported) return;
    await _init();
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static String _title(String meal) => switch (meal) {
        'breakfast' => t('Good morning! What did you have for breakfast?'),
        'lunch' => t('Lunch time. What did you eat?'),
        _ => t('How was dinner? Log what you ate.'),
      };

  /// Reads settings + today's log and (re)schedules. Safe to call often.
  static Future<void> sync() async {
    if (!supported || db.auth.currentUser == null) return;
    await _init();
    final settings = await db.from('reminder_settings').select().eq('user_id', myId).maybeSingle();
    final logged = await db.from('food_entries').select('meal').eq('client_id', myId).eq('logged_on', today());
    final loggedToday = {for (final r in logged) r['meal'] as String};

    for (var i = 0; i < _days * meals.length; i++) {
      await _plugin.cancel(id: _baseId + i);
    }
    if (settings == null || settings['enabled'] != true) return;

    final now = tz.TZDateTime.now(tz.local);
    for (var day = 0; day < _days; day++) {
      for (final (i, meal) in meals.indexed) {
        if (day == 0 && loggedToday.contains(meal)) continue;
        final time = parseTime(settings[meal] as String);
        final when = tz.TZDateTime(tz.local, now.year, now.month, now.day + day, time.hour, time.minute);
        if (!when.isAfter(now)) continue;
        await _plugin.zonedSchedule(
          id: _baseId + day * meals.length + i,
          scheduledDate: when,
          title: _title(meal),
          body: t('Tap to add it to your Nouri log.'),
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              'meal_reminders',
              t('Meal reminders'),
              channelDescription: t('Reminders to log breakfast, lunch and dinner'),
            ),
            iOS: DarwinNotificationDetails(),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    }
  }

  /// Cancel everything (sign out).
  static Future<void> clear() async {
    if (!supported || !_ready) return;
    await _plugin.cancelAll();
  }
}

/// "08:30:00" -> TimeOfDay(8, 30)
TimeOfDay parseTime(String s) {
  final p = s.split(':');
  return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
}

String formatTime(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
