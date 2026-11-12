import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/i18n.dart';

/// Water for the day: one glass that fills towards the goal, quick adds for
/// a glass / bottle / litre, "set total" for people who'd rather enter the
/// day's amount at once, and undo.
class WaterTracker extends StatelessWidget {
  const WaterTracker({
    super.key,
    required this.consumedMl,
    required this.targetMl,
    required this.onAdd,
    required this.onUndo,
    required this.onSetTotal,
  });

  final int consumedMl;
  final int targetMl;
  final ValueChanged<int> onAdd;
  final VoidCallback? onUndo; // null when there is nothing to undo
  final ValueChanged<int> onSetTotal;

  @override
  Widget build(BuildContext context) {
    final c = context.nouri;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final progress = targetMl <= 0 ? 0.0 : (consumedMl / targetMl).clamp(0, 1).toDouble();
    final remaining = targetMl - consumedMl;

    Widget quickAdd(String label, int ml, IconData icon) => Expanded(
          child: FilledButton.tonalIcon(
            onPressed: () => onAdd(ml),
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
            style: FilledButton.styleFrom(
              backgroundColor: c.water.withValues(alpha: 0.16),
              foregroundColor: Theme.of(context).brightness == Brightness.dark ? c.water : const Color(0xFF0B4F99),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      decoration: BoxDecoration(color: c.waterSoft, borderRadius: BorderRadius.circular(22)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Semantics(
            label: t('Water {0} of {1} litres', [_litres(consumedMl), _litres(targetMl)]),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: progress),
              duration: const Duration(milliseconds: 550),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => CustomPaint(size: const Size(58, 78), painter: _GlassPainter(v, c.water)),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.water_drop_rounded, color: c.water, size: 18),
                const SizedBox(width: 6),
                Text(t('Water'), style: text.titleMedium),
              ]),
              const SizedBox(height: 2),
              Text.rich(TextSpan(children: [
                TextSpan(text: _litres(consumedMl), style: text.headlineMedium?.copyWith(color: c.water, fontWeight: FontWeight.w800)),
                TextSpan(text: t(' / {0} L', [_litres(targetMl)]), style: text.titleMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ])),
              Text(
                remaining <= 0 ? t('Goal reached, nicely done!') : t('{0} to go', [_amount(remaining)]),
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          quickAdd(t('Glass'), 250, Icons.local_drink_rounded),
          const SizedBox(width: 8),
          quickAdd(t('Bottle'), 500, Icons.water_rounded),
          const SizedBox(width: 8),
          quickAdd('1 L', 1000, Icons.add_rounded),
        ]),
        Row(children: [
          TextButton.icon(
            onPressed: () async {
              final ml = await _askTotal(context, consumedMl);
              if (ml != null) onSetTotal(ml);
            },
            icon: const Icon(Icons.edit_rounded, size: 18),
            label: Text(t('Set total')),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: onUndo,
            icon: const Icon(Icons.undo_rounded, size: 18),
            label: Text(t('Undo')),
          ),
        ]),
      ]),
    );
  }
}

/// Ask for the day's total in litres (or ml). Returns millilitres.
Future<int?> _askTotal(BuildContext context, int currentMl) {
  final ctrl = TextEditingController(text: currentMl == 0 ? '' : _litres(currentMl));
  String? error;
  return showDialog<int>(
    context: context,
    builder: (c) => StatefulBuilder(builder: (c, set) {
      void submit() {
        final raw = ctrl.text.trim().replaceAll(',', '.');
        final v = double.tryParse(raw);
        // Accept litres ("1.5") or millilitres ("1500").
        final ml = v == null ? null : (v > 20 ? v.round() : (v * 1000).round());
        if (ml == null || ml < 0 || ml > 10000) {
          set(() => error = t('Enter an amount between 0 and 10 litres.'));
          return;
        }
        Navigator.pop(c, ml);
      }

      return AlertDialog(
        title: Text(t('Water today')),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t('How much did you drink in total today? This replaces what you logged so far.')),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: t('Total'), suffixText: 'L', errorText: error, hintText: 'e.g. 1.5'),
              onSubmitted: (_) => submit(),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final l in ['1', '1.5', '2', '2.5', '3'])
                ActionChip(label: Text(t('{0} L', [l])), onPressed: () => set(() => ctrl.text = l)),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(t('Cancel'))),
          FilledButton(onPressed: submit, child: Text(t('Save'))),
        ],
      );
    }),
  );
}

/// 1750 -> "1.75", 2000 -> "2", 1800 -> "1.8"
String _litres(int ml) {
  final s = (ml / 1000).toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// 250 -> "250 ml", 1250 -> "1.25 L"
String _amount(int ml) => ml < 1000 ? '$ml ml' : '${_litres(ml)} L';

class _GlassPainter extends CustomPainter {
  _GlassPainter(this.fill, this.color);
  final double fill;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final inset = s.width * 0.13;
    final glass = Path()
      ..moveTo(0, 0)
      ..lineTo(s.width, 0)
      ..lineTo(s.width - inset, s.height)
      ..lineTo(inset, s.height)
      ..close();

    canvas.save();
    canvas.clipPath(glass);
    canvas.drawRect(Offset.zero & s, Paint()..color = color.withValues(alpha: 0.10));
    if (fill > 0) {
      final top = s.height * (1 - fill);
      final water = Path()..moveTo(0, top);
      for (var x = 0.0; x <= s.width; x += 1) {
        water.lineTo(x, top + math.sin(x / s.width * math.pi * 2) * (fill < 1 ? 2.2 : 0));
      }
      water
        ..lineTo(s.width, s.height)
        ..lineTo(0, s.height)
        ..close();
      canvas.drawPath(
        water,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.7), color],
          ).createShader(Offset.zero & s),
      );
      canvas.drawRect(
        Rect.fromLTWH(s.width * 0.2, top + 5, s.width * 0.09, (s.height - top) * 0.6),
        Paint()..color = Colors.white.withValues(alpha: 0.35),
      );
    }
    canvas.restore();
    canvas.drawPath(
      glass,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_GlassPainter old) => old.fill != fill || old.color != color;
}
