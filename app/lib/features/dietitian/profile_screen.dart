import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../widgets/common.dart';
import '../../core/i18n.dart';

/// Workspace profile shown to clients, plus credential verification.
class DietitianProfileScreen extends StatefulWidget {
  const DietitianProfileScreen({super.key});

  @override
  State<DietitianProfileScreen> createState() => _DietitianProfileScreenState();
}

class _DietitianProfileScreenState extends State<DietitianProfileScreen> {
  late Future<Map<String, dynamic>> _future = _load();
  final _name = TextEditingController();
  final _title = TextEditingController();
  final _specialties = TextEditingController();
  final _bio = TextEditingController();
  final _city = TextEditingController();
  final _years = TextEditingController();
  final _capacity = TextEditingController();
  bool _online = true;
  bool _inPerson = false;
  bool _listed = true;
  bool _busy = false;

  Future<Map<String, dynamic>> _load() async {
    final p = await db.from('profiles').select('full_name').eq('id', myId).single();
    final d = await db.from('dietitian_profiles').select().eq('user_id', myId).single();
    final subs = await db.from('verification_submissions').select().eq('dietitian_id', myId).order('submitted_at', ascending: false).limit(1);
    _name.text = p['full_name'] as String? ?? '';
    _title.text = d['title'] as String? ?? '';
    _specialties.text = List<String>.from(d['specialties'] as List? ?? const []).join(', ');
    _bio.text = d['bio'] as String? ?? '';
    _city.text = d['city'] as String? ?? '';
    _years.text = d['years_experience']?.toString() ?? '';
    _capacity.text = d['capacity']?.toString() ?? '';
    _online = d['works_online'] as bool? ?? true;
    _inPerson = d['works_in_person'] as bool? ?? false;
    _listed = d['listed'] as bool? ?? true;
    return {...d, 'last_submission': subs.isEmpty ? null : subs.first};
  }

  String? _nullIfEmpty(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await db.from('profiles').update({'full_name': _nullIfEmpty(_name)}).eq('id', myId);
      await db.from('dietitian_profiles').update({
        'title': _nullIfEmpty(_title),
        'specialties': _specialties.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
        'bio': _nullIfEmpty(_bio),
        'city': _nullIfEmpty(_city),
        'years_experience': int.tryParse(_years.text.trim()),
        'capacity': int.tryParse(_capacity.text.trim()),
        'works_online': _online,
        'works_in_person': _inPerson,
        'listed': _listed,
      }).eq('user_id', myId);
      if (mounted) showInfo(context, t('Profile saved.'));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png']);
    if (files.isEmpty) return;
    final file = files.first;
    setState(() => _busy = true);
    try {
      final ext = (file.extension ?? 'pdf').toLowerCase();
      final path = '$myId/${DateTime.now().millisecondsSinceEpoch}.$ext';
      await db.storage.from('credentials').uploadBinary(path, await file.readAsBytes());
      await db.rpc('submit_verification', params: {'p_document_path': path});
      if (mounted) showInfo(context, t('Submitted. An admin will review your document.'));
      setState(() => _future = _load());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader<Map<String, dynamic>>(
      future: _future,
      builder: (context, d) {
        final status = d['verification_status'] as String;
        final last = d['last_submission'] as Map<String, dynamic>?;
        return ListView(padding: const EdgeInsets.all(16), children: [
          MaxWidth(
            width: 700,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SectionCard(
                title: t('Verification'),
                action: VerifiedBadge(status: status),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(switch (status) {
                    'approved' => t('Your credentials are verified.'),
                    'pending' => t('Submitted {0}. An admin is reviewing it.', [dateTimeFmt.format(parseTs(last?['submitted_at'])!)]),
                    'rejected' => t('Not approved: {0}', [last?['review_note'] ?? '']),
                    _ => t('Upload a diploma or certificate (PDF, JPG or PNG). Until it is approved, clients see an "Unverified" badge and you can have up to 3 active clients.'),
                  }),
                  if (status == 'unsubmitted' || status == 'rejected') ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy ? null : _upload,
                      icon: const Icon(Icons.upload_file),
                      label: Text(t('Upload credential')),
                    ),
                  ],
                ]),
              ),
              SectionCard(
                title: t('Public profile'),
                child: Column(children: [
                  TextField(controller: _name, decoration: InputDecoration(labelText: t('Full name'))),
                  TextField(controller: _title, decoration: InputDecoration(labelText: t('Title'), hintText: t('e.g. RD, MSc Clinical Nutrition'))),
                  TextField(controller: _specialties, decoration: InputDecoration(labelText: t('Specialties (comma separated)'))),
                  TextField(controller: _bio, maxLines: 4, decoration: InputDecoration(labelText: t('Bio'))),
                  Row(children: [
                    Expanded(child: TextField(controller: _city, decoration: InputDecoration(labelText: t('City')))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _years,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: t('Years of experience')),
                      ),
                    ),
                  ]),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _online,
                    onChanged: (v) => setState(() => _online = v ?? true),
                    title: Text(t('I work online')),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _inPerson,
                    onChanged: (v) => setState(() => _inPerson = v ?? false),
                    title: Text(t('I see clients in person')),
                  ),
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _listed,
                    onChanged: (v) => setState(() => _listed = v),
                    title: Text(t('Show me in "Find a dietitian"')),
                    subtitle: Text(status == 'approved'
                        ? t('Clients can find you and send requests. You accept or decline each one.')
                        : t('You will appear in the list once your credential is approved.')),
                  ),
                  TextField(
                    controller: _capacity,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: t('Maximum active clients (optional)'),
                      helperText: t('When you reach it, you are shown as fully booked. Requests still arrive so you can see demand.'),
                      helperMaxLines: 3,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      t('Your photo is your profile picture: change it from the menu at the top right.'),
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(onPressed: _busy ? null : _save, child: Text(t('Save profile'))),
                  ),
                ]),
              ),
            ]),
          ),
        ]);
      },
    );
  }
}
