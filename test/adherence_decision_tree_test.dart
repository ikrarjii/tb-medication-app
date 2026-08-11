import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/services/adherence_decision_tree.dart';

void main() {
  const tree = AdherenceDecisionTree();

  test('95% is SANGAT PATUH', () {
    final decision = tree.evaluatePercentage(95);
    expect(decision.classification, AdherenceClassification.veryHigh);
    expect(decision.displayLabel, 'SANGAT PATUH');
  });

  test('100% is SANGAT PATUH', () {
    expect(
      tree.evaluatePercentage(100).classification,
      AdherenceClassification.veryHigh,
    );
  });

  test('94.99% is CUKUP PATUH', () {
    final decision = tree.evaluatePercentage(94.99);
    expect(decision.classification, AdherenceClassification.moderate);
    expect(decision.displayLabel, 'CUKUP PATUH');
  });

  test('80% is CUKUP PATUH', () {
    expect(
      tree.evaluatePercentage(80).classification,
      AdherenceClassification.moderate,
    );
  });

  test('79.99% is KEPATUHAN RENDAH', () {
    final decision = tree.evaluatePercentage(79.99);
    expect(decision.classification, AdherenceClassification.low);
    expect(decision.displayLabel, 'KEPATUHAN RENDAH');
  });

  test('0% is KEPATUHAN RENDAH', () {
    expect(
      tree.evaluatePercentage(0).classification,
      AdherenceClassification.low,
    );
  });

  test('percentage is calculated from confirmed and scheduled doses', () {
    final decision = tree.evaluate(
      confirmedDoses: 116,
      totalScheduledDoses: 120,
    );
    expect(decision.percentage, closeTo(96.6667, .0001));
    expect(decision.classification, AdherenceClassification.veryHigh);
  });

  test('decision path records every traversed node', () {
    final decision = tree.evaluate(
      confirmedDoses: 105,
      totalScheduledDoses: 120,
    );
    expect(decision.reasoningPath, [
      'Adherence Percentage: 87.5%',
      'Node 1: Is adherence >= 95%? NO',
      'Node 2: Is adherence >= 80%? YES',
      'Final Result: CUKUP PATUH',
    ]);
  });

  test('no scheduled doses produces deterministic 0% low adherence', () {
    final decision = tree.evaluate(confirmedDoses: 0, totalScheduledDoses: 0);
    expect(decision.percentage, 0);
    expect(decision.classification, AdherenceClassification.low);
  });
}
