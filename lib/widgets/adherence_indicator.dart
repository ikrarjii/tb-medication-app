import 'package:flutter/material.dart';

import '../services/adherence_decision_tree.dart';

enum AdherenceLevel { low, medium, high }

AdherenceLevel adherenceLevelFromMedicines({
  required int confirmedDoses,
  required int totalScheduledDoses,
}) {
  final decision = const AdherenceDecisionTree().evaluate(
    confirmedDoses: confirmedDoses,
    totalScheduledDoses: totalScheduledDoses,
  );
  return switch (decision.classification) {
    AdherenceClassification.veryHigh => AdherenceLevel.high,
    AdherenceClassification.moderate => AdherenceLevel.medium,
    AdherenceClassification.low => AdherenceLevel.low,
  };
}

class AdherenceIndicator extends StatelessWidget {
  const AdherenceIndicator({
    super.key,
    required this.confirmedDoses,
    required this.totalScheduledDoses,
    this.compact = false,
  });

  final int confirmedDoses;
  final int totalScheduledDoses;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final decision = const AdherenceDecisionTree().evaluate(
      confirmedDoses: confirmedDoses,
      totalScheduledDoses: totalScheduledDoses,
    );
    final level = switch (decision.classification) {
      AdherenceClassification.veryHigh => AdherenceLevel.high,
      AdherenceClassification.moderate => AdherenceLevel.medium,
      AdherenceClassification.low => AdherenceLevel.low,
    };
    final (label, detail, color, icon) = switch (level) {
      AdherenceLevel.high => (
        decision.displayLabel,
        'Minimal 95% dosis terjadwal telah dikonfirmasi',
        const Color(0xFF228B64),
        Icons.check_circle_rounded,
      ),
      AdherenceLevel.medium => (
        decision.displayLabel,
        '80%–94,99% dosis terjadwal telah dikonfirmasi',
        const Color(0xFFE0A11B),
        Icons.warning_amber_rounded,
      ),
      AdherenceLevel.low => (
        decision.displayLabel,
        'Kurang dari 80% dosis terjadwal dikonfirmasi',
        const Color(0xFFD24F4A),
        Icons.error_rounded,
      ),
    };

    return Semantics(
      label: '$label, ${decision.formattedPercentage} persen',
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(compact ? 8 : 11),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: compact ? 22 : 28),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 14 : 17,
                  ),
                ),
                if (!compact)
                  Text('${decision.formattedPercentage}% · $detail'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
