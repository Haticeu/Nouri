import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../core/i18n.dart';

/// Client asks their dietitian to change targets. The dietitian gets a
/// notification (DB trigger) and answers from the client's Requests tab.
Future<void> requestTargetChange(BuildContext context, String dietitianId, Map<String, dynamic>? current) async {
  final message = TextEditingController();
  final kcal = TextEditingController();
  final protein = TextEditingController();
  final send = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(t('Request a target change')),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: message,
            autofocus: true,
            maxLines: 3,
            decoration: InputDecoration(labelText: t('What would you like to change, and why?')),
          ),
          TextField(
            controller: kcal,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: t('Suggested calories (optional)'), helperText: t('Current: {0} kcal', [current?['calories'] ?? '–'])),
          ),
          TextField(
            controller: protein,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: t('Suggested protein g (optional)'), helperText: t('Current: {0} g', [current?['protein_g'] ?? '–'])),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Send request'))),
      ],
    ),
  );
  if (send != true || message.text.trim().isEmpty) return;
  try {
    await db.from('target_change_requests').insert({
      'client_id': myId,
      'dietitian_id': dietitianId,
      'message': message.text.trim(),
      'requested_calories': int.tryParse(kcal.text),
      'requested_protein_g': int.tryParse(protein.text),
    });
    if (context.mounted) showInfo(context, t('Request sent to your dietitian.'));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
