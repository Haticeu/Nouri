import 'package:flutter/material.dart';

import '../core/nutrition_safety.dart';
import '../core/session.dart';
import '../core/ui.dart';
import '../core/i18n.dart';

/// Shows targets plus the shared safety warnings. Used by clients and dietitians.
class TargetsView extends StatelessWidget {
  const TargetsView({super.key, required this.targets});
  final Map<String, dynamic>? targets;

  @override
  Widget build(BuildContext context) {
    final tg = targets;
    if (tg == null) return EmptyHint(t('No targets set yet.'));
    String v(String k, String unit) => tg[k] == null ? '–' : '${tg[k]} $unit';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 24, runSpacing: 8, children: [
          _Stat(t('Calories'), v('calories', 'kcal')),
          _Stat(t('Protein'), v('protein_g', 'g')),
          _Stat(t('Carbs'), v('carbs_g', 'g')),
          _Stat(t('Fat'), v('fat_g', 'g')),
          _Stat(t('Water'), v('water_ml', 'ml')),
        ]),
        WarningList(warnings: warningsFor(tg)),
      ],
    );
  }
}

List<TargetWarning> warningsFor(Map<String, dynamic> t) => targetWarnings(
      calories: t['calories'] as int?,
      proteinG: t['protein_g'] as int?,
      carbsG: t['carbs_g'] as int?,
      fatG: t['fat_g'] as int?,
    );

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ]);
}

class WarningList extends StatelessWidget {
  const WarningList({super.key, required this.warnings});
  final List<TargetWarning> warnings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final w in warnings)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: w.level == SafetyLevel.info ? scheme.surfaceContainerHighest : scheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(w.level == SafetyLevel.info ? Icons.info_outline : Icons.warning_amber_rounded,
                  color: w.level == SafetyLevel.info ? scheme.onSurfaceVariant : scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(child: Text(w.message)), // already translated
            ]),
          ),
      ],
    );
  }
}

/// Edit targets for [clientId]. The same safety warnings apply whoever edits;
/// saving a target with a caution/danger warning requires confirmation.
Future<bool> editTargets(BuildContext context, String clientId, Map<String, dynamic>? current,
    {required bool asDietitian}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _TargetsDialog(clientId: clientId, current: current, asDietitian: asDietitian),
  );
  return saved ?? false;
}

class _TargetsDialog extends StatefulWidget {
  const _TargetsDialog({required this.clientId, required this.current, required this.asDietitian});
  final String clientId;
  final Map<String, dynamic>? current;
  final bool asDietitian;

  @override
  State<_TargetsDialog> createState() => _TargetsDialogState();
}

class _TargetsDialogState extends State<_TargetsDialog> {
  static final _fields = {
    'calories': t('Calories (kcal)'),
    'protein_g': t('Protein (g)'),
    'carbs_g': t('Carbs (g)'),
    'fat_g': t('Fat (g)'),
    'water_ml': t('Water (ml)'),
  };
  late final Map<String, TextEditingController> _ctrls = {
    for (final k in _fields.keys) k: TextEditingController(text: widget.current?[k]?.toString() ?? ''),
  };
  bool _saving = false;

  Map<String, int?> get _values => {for (final e in _ctrls.entries) e.key: int.tryParse(e.value.text.trim())};

  @override
  Widget build(BuildContext context) {
    final warnings = warningsFor(_values);
    return AlertDialog(
      title: Text(t('Nutrition targets')),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final e in _fields.entries)
              TextField(
                controller: _ctrls[e.key],
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: e.value),
                onChanged: (_) => setState(() {}),
              ),
            WarningList(warnings: warnings),
            if (widget.asDietitian)
              Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(t('Your client will see this change in their history.')),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
        FilledButton(onPressed: _saving ? null : () => _save(warnings), child: Text(t('Save'))),
      ],
    );
  }

  Future<void> _save(List<TargetWarning> warnings) async {
    if (needsConfirmation(warnings)) {
      final ok = await confirm(
        context,
        t('Save a low target?'),
        '${warnings.where((w) => w.level != SafetyLevel.info).map((w) => w.message).join('\n\n')}'
            '\n\n${widget.asDietitian ? t('Confirm this is clinically appropriate for this client.') : t('Consider talking to a professional first.')}',
        ok: t('Save anyway'),
      );
      if (!ok) return;
    }
    setState(() => _saving = true);
    try {
      await db.from('nutrition_targets').upsert({'client_id': widget.clientId, ..._values});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
      setState(() => _saving = false);
    }
  }
}
