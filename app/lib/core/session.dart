import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'push.dart';
import 'reminders.dart';

SupabaseClient get db => Supabase.instance.client;
String get myId => db.auth.currentUser!.id;

enum UserRole { client, dietitian }

/// Signed-in user, their role and admin flag. Drives routing.
class AppSession extends ChangeNotifier {
  StreamSubscription<AuthState>? _sub;
  UserRole? role;
  String? fullName;
  String? avatarUrl;
  bool isAdmin = false;
  /// A client who hasn't answered the first-run questions yet.
  bool needsOnboarding = false;
  bool loading = true;

  bool get signedIn => db.auth.currentUser != null;
  String? get email => db.auth.currentUser?.email;

  Future<void> load() async {
    _sub ??= db.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.signedIn ||
          event.event == AuthChangeEvent.signedOut ||
          event.event == AuthChangeEvent.userUpdated) {
        _refresh();
      }
    });
    await _refresh();
  }

  /// Re-read the profile (after editing name or photo).
  Future<void> reload() => _refresh(quiet: true);

  Future<void> _refresh({bool quiet = false}) async {
    if (!quiet) {
      loading = true;
      notifyListeners();
    }
    if (!signedIn) {
      role = null;
      fullName = null;
      avatarUrl = null;
      isAdmin = false;
      needsOnboarding = false;
    } else {
      final profile = await db.from('profiles').select('role, full_name, avatar_url, timezone, onboarded_at').eq('id', myId).maybeSingle();
      role = profile?['role'] == 'dietitian' ? UserRole.dietitian : UserRole.client;
      fullName = profile?['full_name'] as String?;
      avatarUrl = profile?['avatar_url'] as String?;
      needsOnboarding = role == UserRole.client && profile != null && profile['onboarded_at'] == null;
      final admin = await db.from('admins').select('user_id').eq('user_id', myId).maybeSingle();
      isAdmin = admin != null;
      if (!quiet) unawaited(_syncTimezone(profile?['timezone'] as String?));
      if (!quiet && role == UserRole.client) unawaited(Reminders.sync());
      if (!quiet) unawaited(Push.register());
    }
    loading = false;
    notifyListeners();
  }

  /// Keep profiles.timezone (used for "today" on the dietitian's dashboard) in
  /// line with the device.
  Future<void> _syncTimezone(String? current) async {
    try {
      final zone = (await FlutterTimezone.getLocalTimezone()).identifier;
      if (zone.isNotEmpty && zone != current) {
        await db.from('profiles').update({'timezone': zone}).eq('id', myId);
      }
    } catch (_) {
      // Not critical; the server keeps the previous value.
    }
  }

  Future<void> signOut() async {
    await Reminders.clear();
    await Push.unregister();
    await db.auth.signOut();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
