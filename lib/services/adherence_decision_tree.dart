enum AdherenceClassification {
  veryHigh('VERY HIGH ADHERENCE', 'SANGAT PATUH'),
  moderate('MODERATE ADHERENCE', 'CUKUP PATUH'),
  low('LOW ADHERENCE', 'KEPATUHAN RENDAH');

  const AdherenceClassification(this.technicalLabel, this.displayLabel);

  final String technicalLabel;
  final String displayLabel;
}

class AdherenceDecision {
  const AdherenceDecision({
    required this.classification,
    required this.percentage,
    required this.confirmedDoses,
    required this.totalScheduledDoses,
    required this.reasoningPath,
  });

  final AdherenceClassification classification;
  final double percentage;
  final int confirmedDoses;
  final int totalScheduledDoses;
  final List<String> reasoningPath;

  String get displayLabel => classification.displayLabel;
  String get classificationReason => reasoningPath.join('\n');
  String get formattedPercentage => _formatPercentage(percentage);
}

/// Deterministic medication-adherence decision tree.
///
/// This classifier intentionally has no treatment, BTA, conversion, reversal,
/// or failure inputs. Its result cannot alter a treatment outcome.
class AdherenceDecisionTree {
  const AdherenceDecisionTree();

  AdherenceDecision evaluate({
    required int confirmedDoses,
    required int totalScheduledDoses,
  }) {
    if (confirmedDoses < 0 || totalScheduledDoses < 0) {
      throw ArgumentError('Jumlah dosis tidak boleh negatif.');
    }
    if (confirmedDoses > totalScheduledDoses) {
      throw ArgumentError(
        'Dosis terkonfirmasi tidak boleh melebihi dosis terjadwal.',
      );
    }
    final percentage = totalScheduledDoses == 0
        ? 0.0
        : confirmedDoses / totalScheduledDoses * 100;
    return evaluatePercentage(
      percentage,
      confirmedDoses: confirmedDoses,
      totalScheduledDoses: totalScheduledDoses,
    );
  }

  AdherenceDecision evaluatePercentage(
    double percentage, {
    int confirmedDoses = 0,
    int totalScheduledDoses = 0,
  }) {
    if (!percentage.isFinite || percentage < 0 || percentage > 100) {
      throw ArgumentError.value(
        percentage,
        'percentage',
        'Persentase harus berada pada rentang 0 sampai 100.',
      );
    }

    final path = <String>[
      'Adherence Percentage: ${_formatPercentage(percentage)}%',
    ];
    final isVeryHigh = percentage >= 95;
    path.add('Node 1: Is adherence >= 95%? ${isVeryHigh ? 'YES' : 'NO'}');
    if (isVeryHigh) {
      return _decision(
        classification: AdherenceClassification.veryHigh,
        percentage: percentage,
        confirmedDoses: confirmedDoses,
        totalScheduledDoses: totalScheduledDoses,
        path: path,
      );
    }

    final isModerate = percentage >= 80;
    path.add('Node 2: Is adherence >= 80%? ${isModerate ? 'YES' : 'NO'}');
    return _decision(
      classification: isModerate
          ? AdherenceClassification.moderate
          : AdherenceClassification.low,
      percentage: percentage,
      confirmedDoses: confirmedDoses,
      totalScheduledDoses: totalScheduledDoses,
      path: path,
    );
  }

  AdherenceDecision _decision({
    required AdherenceClassification classification,
    required double percentage,
    required int confirmedDoses,
    required int totalScheduledDoses,
    required List<String> path,
  }) => AdherenceDecision(
    classification: classification,
    percentage: percentage,
    confirmedDoses: confirmedDoses,
    totalScheduledDoses: totalScheduledDoses,
    reasoningPath: [...path, 'Final Result: ${classification.displayLabel}'],
  );
}

String _formatPercentage(double value) {
  final fixed = value.toStringAsFixed(2);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}
