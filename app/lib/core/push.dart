import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'session.dart';

/// Push notifications to the phone (Firebase Cloud Messaging).
///
/// Off until a Firebase project exists. Turn on by building with:
///   --dart-define=FIREBASE_API_KEY=... --dart-define=FIREBASE_APP_ID=...
///   --dart-define=FIREBASE_SENDER_ID=... --dart-define=FIREBASE_PROJECT_ID=...
/// (from Firebase console -> Project settings -> Your apps -> Android app).
/// These identify the app; they are not secrets. The secret that SENDS pushes
/// (the service account) lives only in Supabase secrets, used by the
/// `send-push` Edge Function.
///
/// Flow: the app registers its FCM token in `device_tokens`; a Database
/// Webhook on `notifications` INSERT calls `send-push`, which delivers to the
/// user's tokens and sets `notifications.pushed_at`.
class Push {
  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

  static bool get enabled =>
      !kIsWeb && _apiKey != '' && _appId != '' && _senderId != '' && _projectId != '';

  static StreamSubscription<String>? _refresh;

  /// Call after sign-in. Does nothing when push isn't configured.
  static Future<void> register() async {
    if (!enabled) return;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: const FirebaseOptions(apiKey: _apiKey, appId: _appId, messagingSenderId: _senderId, projectId: _projectId),
        );
      }
      final messaging = FirebaseMessaging.instance;
      final perm = await messaging.requestPermission();
      if (perm.authorizationStatus == AuthorizationStatus.denied) return;
      // The classic FCM token: send-push uses it with the documented HTTP v1 API.
      // (firebase_messaging 17 deprecates it in favour of installation IDs.)
      // ignore: deprecated_member_use
      final token = await messaging.getToken();
      if (token != null) await _save(token);
      // ignore: deprecated_member_use
      _refresh ??= messaging.onTokenRefresh.listen(_save);
    } catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }

  static Future<void> _save(String token) => db.from('device_tokens').upsert({
        'token': token,
        'user_id': myId,
        'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

  /// Call before sign-out so this phone stops getting the user's notifications.
  static Future<void> unregister() async {
    if (!enabled || Firebase.apps.isEmpty) return;
    try {
      // ignore: deprecated_member_use
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await db.from('device_tokens').delete().eq('token', token);
      await _refresh?.cancel();
      _refresh = null;
    } catch (_) {}
  }
}
