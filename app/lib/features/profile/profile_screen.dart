import 'package:flutter/material.dart';

import '../onboarding/onboarding_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/reminders.dart';
import '../../core/session.dart';
import '../../core/ui.dart';
import '../../widgets/common.dart';
import '../../core/i18n.dart';

/// Personal profile & settings for any signed-in user (from the top-right menu).
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.session});
  final AppSession session;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<Map<String, dynamic>> _future = _load();
  final _name = TextEditingController();
  final _height = TextEditingController();
  DateTime? _birth;
  String? _sex;
  bool _busy = false;

  bool get _isClient => widget.session.role == UserRole.client;

  Future<Map<String, dynamic>> _load() async {
    final p = await db.from('profiles').select().eq('id', myId).single();
    final r = await db.from('reminder_settings').select().eq('user_id', myId).maybeSingle();
    _name.text = p['full_name'] as String? ?? '';
    _height.text = p['height_cm'] == null ? '' : '${asNum(p['height_cm'])}';
    _birth = p['birth_date'] == null ? null : DateTime.parse(p['birth_date'] as String);
    _sex = p['sex'] as String?;
    return {'profile': p, 'reminders': r};
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _changePhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 800, imageQuality: 85);
    if (x == null) return;
    setState(() => _busy = true);
    try {
      final path = '$myId/avatar-${DateTime.now().millisecondsSinceEpoch}.jpg';
      await db.storage.from('avatars').uploadBinary(path, await x.readAsBytes());
      await _setPhoto(db.storage.from('avatars').getPublicUrl(path));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPhoto(String? url) async {
    await db.from('profiles').update({'avatar_url': url}).eq('id', myId);
    // A dietitian's public workspace page shows the same photo.
    if (!_isClient) await db.from('dietitian_profiles').update({'photo_url': url}).eq('user_id', myId);
    await widget.session.reload();
    _reload();
  }

  Future<void> _saveDetails() async {
    setState(() => _busy = true);
    try {
      await db.from('profiles').update({
        'full_name': _name.text.trim().isEmpty ? null : _name.text.trim(),
        if (_isClient) ...{
          'birth_date': _birth == null ? null : isoDate.format(_birth!),
          'height_cm': num.tryParse(_height.text.replaceAll(',', '.')),
          'sex': _sex,
        },
      }).eq('id', myId);
      await widget.session.reload();
      if (mounted) showInfo(context, t('Profile saved.'));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateReminders(Map<String, dynamic> changes) async {
    try {
      await db.from('reminder_settings').update({...changes, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('user_id', myId);
      if (changes['enabled'] == true) await Reminders.requestPermission();
      await Reminders.sync();
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('Profile & settings'))),
      body: Loader<Map<String, dynamic>>(
        future: _future,
        builder: (context, d) {
          final p = d['profile'] as Map<String, dynamic>;
          final r = d['reminders'] as Map<String, dynamic>?;
          return ListView(padding: const EdgeInsets.all(16), children: [
            MaxWidth(
              width: 640,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _header(p),
                const SizedBox(height: 16),
                _details(p),
                if (_isClient && r != null) _reminders(r),
                if (_isClient)
                  SectionCard(
                    title: t('Goal and preferences'),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.quiz_outlined),
                      title: Text(t('Answer the questions again')),
                      subtitle: Text(t('Goal, activity, eating style, allergies and habits')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
                          fullscreenDialog: true,
                          builder: (_) => OnboardingScreen(session: widget.session, redo: true),
                        ));
                        if (saved == true) _reload();
                      },
                    ),
                  ),
                SectionCard(
                  title: t('Account'),
                  child: Column(children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.public),
                      title: Text(t('Time zone')),
                      subtitle: Text(t('{0} (set automatically from this device)', [p['timezone']])),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
                      title: Text(t('Sign out')),
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.session.signOut();
                      },
                    ),
                  ]),
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }

  Widget _header(Map<String, dynamic> p) {
    final text = Theme.of(context).textTheme;
    final url = p['avatar_url'] as String?;
    return Column(children: [
      Stack(children: [
        UserAvatar(url: url, name: p['full_name'] as String?, radius: 52),
        Positioned(
          right: 0,
          bottom: 0,
          child: IconButton.filled(
            tooltip: t('Change photo'),
            onPressed: _busy ? null : _changePhoto,
            icon: const Icon(Icons.photo_camera_outlined, size: 20),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      Text(p['full_name'] as String? ?? t('Your name'), style: text.titleLarge),
      Text(widget.session.email ?? '', style: text.bodyMedium),
      if (url != null)
        TextButton(onPressed: _busy ? null : () => _setPhoto(null), child: Text(t('Remove photo'))),
    ]);
  }

  Widget _details(Map<String, dynamic> p) {
    final age = _birth == null ? null : (DateTime.now().difference(_birth!).inDays / 365.25).floor();
    return SectionCard(
      title: t('Personal details'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: _name, decoration: InputDecoration(labelText: t('Full name'))),
        TextField(
          controller: TextEditingController(text: widget.session.email ?? ''),
          enabled: false,
          decoration: InputDecoration(labelText: t('Email')),
        ),
        if (_isClient) ...[
          const SizedBox(height: 12),
          Text(
            t('Shared with your dietitian to help them plan for you.'),
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('Date of birth')),
            subtitle: Text(_birth == null ? t('Not set') : '${DateFormat('d MMMM y').format(_birth!)}${age != null ? t(' · {0} years', [age]) : ''}'),
            trailing: const Icon(Icons.edit_calendar_outlined),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _birth ?? DateTime(1995),
                firstDate: DateTime(1920),
                lastDate: DateTime.now(),
              );
              if (picked != null) setState(() => _birth = picked);
            },
          ),
          TextField(
            controller: _height,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: t('Height (cm)')),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            emptySelectionAllowed: true,
            segments: [
              ButtonSegment(value: 'female', label: Text(t('Female'))),
              ButtonSegment(value: 'male', label: Text(t('Male'))),
              ButtonSegment(value: 'other', label: Text(t('Other'))),
            ],
            selected: {?_sex},
            onSelectionChanged: (s) => setState(() => _sex = s.isEmpty ? null : s.first),
          ),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(onPressed: _busy ? null : _saveDetails, child: Text(t('Save details'))),
        ),
      ]),
    );
  }

  Widget _reminders(Map<String, dynamic> r) {
    final enabled = r['enabled'] == true;
    final labels = {'breakfast': (t('Breakfast'), Icons.free_breakfast_outlined), 'lunch': (t('Lunch'), Icons.lunch_dining_outlined), 'dinner': (t('Dinner'), Icons.dinner_dining_outlined)};
    const defaults = {'breakfast': '08:30', 'lunch': '12:30', 'dinner': '19:30'};
    return SectionCard(
      title: t('Meal reminders'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: enabled,
          onChanged: (v) => _updateReminders({'enabled': v}),
          title: Text(t('Remind me to log my meals')),
          subtitle: Text(t('A gentle nudge at each meal time. Skipped if you already logged that meal.')),
        ),
        for (final meal in Reminders.meals)
          ListTile(
            enabled: enabled,
            contentPadding: EdgeInsets.zero,
            leading: Icon(labels[meal]!.$2),
            title: Text(labels[meal]!.$1),
            trailing: OutlinedButton.icon(
              onPressed: !enabled
                  ? null
                  : () async {
                      final t = await showTimePicker(context: context, initialTime: parseTime(r[meal] as String));
                      if (t != null) await _updateReminders({meal: formatTime(t)});
                    },
              icon: const Icon(Icons.schedule, size: 18),
              label: Text(formatTime(parseTime(r[meal] as String))),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: enabled ? () => _updateReminders(defaults) : null,
            child: Text(t('Reset to default times')),
          ),
        ),
        if (!Reminders.supported)
          Text(
            t('Reminders are delivered by the Nouri mobile app. Times you set here apply on your phone.'),
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
      ]),
    );
  }
}
