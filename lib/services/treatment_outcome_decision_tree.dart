import '../models/bta_examination.dart';
import '../models/treatment_monitoring.dart';

enum TreatmentOutcome {
  cured('CURED'),
  treatmentCompleted('TREATMENT COMPLETED'),
  failed('FAILED'),
  treatmentInProgress('TREATMENT IN PROGRESS');

  const TreatmentOutcome(this.label);
  final String label;
}

class TreatmentOutcomeDecision {
  const TreatmentOutcomeDecision({
    required this.outcome,
    required this.conversionDetected,
    required this.possibleReversal,
    required this.confirmedReversal,
    required this.confirmedFailure,
    required this.reasoningPath,
  });

  final TreatmentOutcome outcome;
  final bool conversionDetected;
  final bool possibleReversal;
  final bool confirmedReversal;
  final bool confirmedFailure;
  final List<String> reasoningPath;

  String get classificationReason => reasoningPath.join('\n');
}

/// Deterministic, auditable WHO-style treatment outcome rule tree.
///
/// Medication adherence is intentionally absent from the input contract. It is
/// a monitoring indicator and can never directly produce CURED or FAILED.
class TreatmentOutcomeDecisionTree {
  const TreatmentOutcomeDecisionTree();

  TreatmentOutcomeDecision evaluate({
    required TreatmentMonitoring treatment,
    required List<BtaExamination> examinations,
  }) {
    final chronological = examinations.where((exam) => exam.hasResult).toList()
      ..sort(_chronologicalCompare);
    final valid = chronological
        .where((exam) => exam.result!.isBacteriologicallyValid)
        .toList(growable: false);
    final initial = _latestOfType(chronological, BtaExaminationType.initial);
    final finalExam = _latestOfType(
      chronological,
      BtaExaminationType.finalExam,
    );

    final conversionIndex = _conversionIndex(valid);
    final conversionDetected = conversionIndex != null;
    final reversal = _reversalState(valid, conversionIndex);
    final confirmedFailure =
        treatment.hasConfirmedFailure || reversal.confirmed;
    final initialPositive = initial?.result == BtaResult.positive;
    final finalNegative = finalExam?.result == BtaResult.negative;
    final path = <String>[];

    path.add(
      'Treatment completed? ${treatment.treatmentCompleted ? 'YES' : 'NO'}',
    );
    if (!treatment.treatmentCompleted) {
      path.add(
        'Confirmed treatment failure? ${confirmedFailure ? 'YES' : 'NO'}',
      );
      return _decision(
        outcome: confirmedFailure
            ? TreatmentOutcome.failed
            : TreatmentOutcome.treatmentInProgress,
        conversionDetected: conversionDetected,
        reversal: reversal,
        confirmedFailure: confirmedFailure,
        path: path,
      );
    }

    path.add('Initial BTA positive? ${initialPositive ? 'YES' : 'NO'}');
    if (initialPositive) {
      path.add('BTA conversion detected? ${conversionDetected ? 'YES' : 'NO'}');
      if (conversionDetected) {
        path.add(
          'Confirmed bacteriological reversal? '
          '${reversal.confirmed ? 'YES' : 'NO'}',
        );
        if (reversal.confirmed) {
          return _decision(
            outcome: TreatmentOutcome.failed,
            conversionDetected: conversionDetected,
            reversal: reversal,
            confirmedFailure: true,
            path: path,
          );
        }

        path.add('Final BTA negative? ${finalNegative ? 'YES' : 'NO'}');
        if (finalNegative) {
          path.add(
            'Confirmed treatment failure? ${confirmedFailure ? 'YES' : 'NO'}',
          );
          return _decision(
            outcome: confirmedFailure
                ? TreatmentOutcome.failed
                : TreatmentOutcome.cured,
            conversionDetected: conversionDetected,
            reversal: reversal,
            confirmedFailure: confirmedFailure,
            path: path,
          );
        }
      }
    }

    path.add('Confirmed treatment failure? ${confirmedFailure ? 'YES' : 'NO'}');
    return _decision(
      outcome: confirmedFailure
          ? TreatmentOutcome.failed
          : TreatmentOutcome.treatmentCompleted,
      conversionDetected: conversionDetected,
      reversal: reversal,
      confirmedFailure: confirmedFailure,
      path: path,
    );
  }

  TreatmentOutcomeDecision _decision({
    required TreatmentOutcome outcome,
    required bool conversionDetected,
    required _ReversalState reversal,
    required bool confirmedFailure,
    required List<String> path,
  }) => TreatmentOutcomeDecision(
    outcome: outcome,
    conversionDetected: conversionDetected,
    possibleReversal: reversal.possible,
    confirmedReversal: reversal.confirmed,
    confirmedFailure: confirmedFailure,
    reasoningPath: [...path, 'Final classification: ${outcome.label}'],
  );

  int? _conversionIndex(List<BtaExamination> valid) {
    var positiveSeen = false;
    for (var index = 0; index < valid.length; index++) {
      if (valid[index].result == BtaResult.positive) positiveSeen = true;
      if (positiveSeen && valid[index].result == BtaResult.negative) {
        return index;
      }
    }
    return null;
  }

  _ReversalState _reversalState(
    List<BtaExamination> valid,
    int? conversionIndex,
  ) {
    if (conversionIndex == null) return const _ReversalState();
    BtaExamination? possiblePositive;
    for (var index = conversionIndex + 1; index < valid.length; index++) {
      final exam = valid[index];
      if (possiblePositive != null && exam.isConfirmation) {
        if (exam.result == BtaResult.positive) {
          return const _ReversalState(possible: true, confirmed: true);
        }
        possiblePositive = null;
        continue;
      }
      if (exam.result != BtaResult.positive) continue;
      possiblePositive ??= exam;
    }
    return _ReversalState(possible: possiblePositive != null);
  }

  BtaExamination? _latestOfType(
    List<BtaExamination> examinations,
    BtaExaminationType type,
  ) {
    BtaExamination? result;
    for (final exam in examinations) {
      if (exam.type == type) result = exam;
    }
    return result;
  }

  static int _chronologicalCompare(
    BtaExamination first,
    BtaExamination second,
  ) {
    final firstDate = first.examinationDate ?? first.scheduledDate;
    final secondDate = second.examinationDate ?? second.scheduledDate;
    final byDate = firstDate.compareTo(secondDate);
    if (byDate != 0) return byDate;
    return first.id.compareTo(second.id);
  }
}

class _ReversalState {
  const _ReversalState({this.possible = false, this.confirmed = false});

  final bool possible;
  final bool confirmed;
}
