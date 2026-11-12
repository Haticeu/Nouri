import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/ui.dart';
import '../core/i18n.dart';

/// Weight over time. [entries] are weight_entries rows, any order.
class WeightChart extends StatelessWidget {
  const WeightChart({super.key, required this.entries});
  final List<Map<String, dynamic>> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.length < 2) return EmptyHint(t('Log at least two weigh-ins to see a chart.'));
    final sorted = [...entries]..sort((a, b) => (a['measured_on'] as String).compareTo(b['measured_on'] as String));
    final first = DateTime.parse(sorted.first['measured_on'] as String);
    final spots = [
      for (final e in sorted)
        FlSpot(
          DateTime.parse(e['measured_on'] as String).difference(first).inDays.toDouble(),
          asNum(e['weight_kg'])!.toDouble(),
        ),
    ];
    final ys = spots.map((s) => s.y);
    final minY = (ys.reduce((a, b) => a < b ? a : b) - 1).floorToDouble();
    final maxY = (ys.reduce((a, b) => a > b ? a : b) + 1).ceilToDouble();
    final color = Theme.of(context).colorScheme.primary;
    final fmt = DateFormat('d MMM');
    return SizedBox(
      height: 220,
      child: LineChart(LineChartData(
        minY: minY,
        maxY: maxY,
        gridData: const FlGridData(drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: (spots.last.x / 4).clamp(1, double.infinity),
              getTitlesWidget: (v, meta) => SideTitleWidget(
                meta: meta,
                child: Text(fmt.format(first.add(Duration(days: v.round()))), style: const TextStyle(fontSize: 11)),
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(spots: spots, color: color, barWidth: 3, dotData: const FlDotData(show: true)),
        ],
      )),
    );
  }
}
