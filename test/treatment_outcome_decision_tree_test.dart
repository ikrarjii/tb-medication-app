import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/models/bta_examination.dart';
import 'package:flutter_application_1/models/treatment_monitoring.dart';
import 'package:flutter_application_1/models/treatment_plan.dart';
import 'package:flutter_application_1/services/adherence_decision_tree.dart';
import 'package:flutter_application_1/services/treatment_outcome_decision_tree.dart';

void main() {
  const tree = TreatmentOutcomeDecisionTree();
  final start = DateTime(2026, 1, 10);

  TreatmentMonitoring treatment({
    TreatmentStatus status = TreatmentStatus.completed,
    ConfirmedFailureType failure = ConfirmedFailureType.none,
  }) => TreatmentMonitoring(
    patientId: 'patient-1',
    treatmentStartDate: start,
    expectedCompletionDate: TreatmentPlan.addMonths(start, 6),
    actualCompletionDate: status == TreatmentStatus.completed
        ? TreatmentPlan.addMonths(start, 6)
        : null,
    status: status,
    confirmedFailureType: failure,
  );

  BtaExamination exam(
    int order,
    BtaResult result, {
    BtaExaminationType? type,
  }) => BtaExamination(
    id: 'exam-$order',
    patientId: 'patient-1',
    type:
        type ??
        switch (order) {
          0 => BtaExaminationType.initial,
          1 => BtaExaminationType.month2,
          2 => BtaExaminationType.preFinal,
          _ => BtaExaminationType.finalExam,
        },
    scheduledDate: TreatmentPlan.addMonths(start, order * 2),
    examinationDate: TreatmentPlan.addMonths(start, order * 2),
    result: result,
  );

  test('TEST 1: positive to repeated negative and completed is CURED', () {
    final decision = tree.evaluate(
      treatment: treatment(),
      examinations: [
        exam(0, BtaResult.positive),
        exam(1, BtaResult.negative),
        exam(2, BtaResult.negative),
        exam(3, BtaResult.negative),
      ],
    );

    expect(decision.outcome, TreatmentOutcome.cured);
    expect(decision.conversionDetected, isTrue);
    expect(decision.confirmedReversal, isFalse);
  });

  test('TEST 2: final TDL and no failure is TREATMENT COMPLETED', () {
    final decision = tree.evaluate(
      treatment: treatment(),
      examinations: [
        exam(0, BtaResult.positive),
        exam(1, BtaResult.negative),
        exam(2, BtaResult.negative),
        exam(3, BtaResult.tdl),
      ],
    );

    expect(decision.outcome, TreatmentOutcome.treatmentCompleted);
  });

  test('TEST 3: confirmed positive after conversion is FAILED', () {
    final decision = tree.evaluate(
      treatment: treatment(status: TreatmentStatus.ongoing),
      examinations: [
        exam(0, BtaResult.positive),
        exam(1, BtaResult.negative),
        exam(2, BtaResult.positive),
        exam(3, BtaResult.positive, type: BtaExaminationType.confirmation),
      ],
    );

    expect(decision.possibleReversal, isTrue);
    expect(decision.confirmedReversal, isTrue);
    expect(decision.outcome, TreatmentOutcome.failed);
  });

  test('a single positive after conversion requires confirmation', () {
    final decision = tree.evaluate(
      treatment: treatment(status: TreatmentStatus.ongoing),
      examinations: [
        exam(0, BtaResult.positive),
        exam(1, BtaResult.negative),
        exam(2, BtaResult.positive),
      ],
    );

    expect(decision.possibleReversal, isTrue);
    expect(decision.confirmedReversal, isFalse);
    expect(decision.outcome, TreatmentOutcome.treatmentInProgress);
  });

  test('a negative repeat examination clears a possible reversal', () {
    final decision = tree.evaluate(
      treatment: treatment(status: TreatmentStatus.ongoing),
      examinations: [
        exam(0, BtaResult.positive),
        exam(1, BtaResult.negative),
        exam(2, BtaResult.positive),
        exam(3, BtaResult.negative, type: BtaExaminationType.confirmation),
      ],
    );

    expect(decision.possibleReversal, isFalse);
    expect(decision.confirmedReversal, isFalse);
    expect(decision.outcome, TreatmentOutcome.treatmentInProgress);
  });

  test('TEST 4: ongoing treatment with no failure is IN PROGRESS', () {
    final decision = tree.evaluate(
      treatment: treatment(status: TreatmentStatus.ongoing),
      examinations: [exam(0, BtaResult.positive)],
    );

    expect(decision.outcome, TreatmentOutcome.treatmentInProgress);
  });

  test('TEST 5: confirmed permanent regimen change is FAILED', () {
    final decision = tree.evaluate(
      treatment: treatment(
        status: TreatmentStatus.ongoing,
        failure: ConfirmedFailureType.regimenPermanentlyChanged,
      ),
      examinations: const [],
    );

    expect(decision.confirmedFailure, isTrue);
    expect(decision.outcome, TreatmentOutcome.failed);
  });

  test('TEST 6: CURED and CUKUP PATUH remain independent combined results', () {
    final treatmentDecision = tree.evaluate(
      treatment: treatment(),
      examinations: [
        exam(0, BtaResult.positive),
        exam(1, BtaResult.negative),
        exam(2, BtaResult.negative),
        exam(3, BtaResult.negative),
      ],
    );
    final adherenceDecision = const AdherenceDecisionTree().evaluatePercentage(
      85,
    );

    expect(treatmentDecision.outcome, TreatmentOutcome.cured);
    expect(adherenceDecision.classification, AdherenceClassification.moderate);
    expect(adherenceDecision.displayLabel, 'CUKUP PATUH');
  });

  test('BTA monitoring automatically contains four treatment milestones', () {
    final dates = TreatmentPlan.btaMonitoringDates(start);

    expect(dates, hasLength(4));
    expect(dates[0], DateTime(2026, 1, 10));
    expect(dates[1], DateTime(2026, 3, 10));
    expect(dates[2], DateTime(2026, 5, 10));
    expect(dates[3], DateTime(2026, 6, 10));
    expect(dates.toSet(), hasLength(4));
  });

  test('legacy BTA storage value remains compatible with month 3 label', () {
    expect(BtaExaminationType.month2.storageValue, 'month_2');
    expect(BtaExaminationType.month2.label, contains('Bulan ke-3'));
    expect(BtaExaminationType.fromStorage('month2'), BtaExaminationType.month2);
  });
}
