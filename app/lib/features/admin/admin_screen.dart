import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../core/i18n.dart';

/// Admin queue: review uploaded diplomas/certificates and approve or reject.
/// Access is enforced server-side (admin_* RPCs check the admins table).
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late Future<List> _future = _load();

  Future<List> _load() async => await db.rpc('admin_pending_verifications') as List;

  Future<void> _openDocument(String path) async {
    try {
      // Short-lived signed link; the bucket is private.
      final url = await db.storage.from('credentials').createSignedUrl(path, 600);
      if (!mounted) return;
      if (path.toLowerCase().endsWith('.pdf')) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(t('Credential')),
          content: SizedBox(width: 640, child: InteractiveViewer(child: Image.network(url))),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(t('Close')))],
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _review(Map s, bool approve) async {
    String? note;
    if (!approve) {
      note = await promptText(context, t('Reason for rejection'), hint: t('Shown to the dietitian'), maxLines: 3, ok: t('Reject'));
      if (note == null || note.isEmpty) return;
    } else if (!await confirm(context, t('Approve {0}?', [s['full_name']]), t('They will be shown as verified to clients and the 3-client limit will be lifted.'), ok: t('Approve'))) {
      return;
    }
    try {
      await db.rpc('admin_review_verification', params: {'p_submission': s['submission_id'], 'p_approve': approve, 'p_note': note});
      setState(() => _future = _load());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('Admin · Dietitian verification'))),
      body: Loader<List>(
        future: _future,
        builder: (context, rows) => rows.isEmpty
            ? Center(child: Text(t('No pending verifications.')))
            : MaxWidth(
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  for (final s in rows)
                    Card(
                      child: ListTile(
                        title: Text(s['full_name'] as String? ?? t('Unnamed dietitian')),
                        subtitle: Text(t('{0} · submitted {1}', [s['title'] ?? t('No title'), dateTimeFmt.format(parseTs(s['submitted_at'])!)])),
                        trailing: Wrap(spacing: 8, children: [
                          IconButton(tooltip: t('View document'), onPressed: () => _openDocument(s['document_path'] as String), icon: const Icon(Icons.description_outlined)),
                          OutlinedButton(onPressed: () => _review(s as Map, false), child: Text(t('Reject'))),
                          FilledButton(onPressed: () => _review(s as Map, true), child: Text(t('Approve'))),
                        ]),
                      ),
                    ),
                ]),
              ),
      ),
    );
  }
}
