import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/bta_examination.dart';
import '../models/treatment_monitoring.dart';
import '../models/treatment_plan.dart';
import '../models/user_profile.dart';
import '../screens/bta_examination_form_screen.dart';
import '../screens/treatment_status_form_screen.dart';
import '../services/adherence_decision_tree.dart';
import '../services/treatment_monitoring_repository.dart';
import '../services/treatment_outcome_decision_tree.dart';
import 'async_error_view.dart';
import 'app_state_view.dart';

class TreatmentMonitoringPanel extends StatefulWidget {
  const TreatmentMonitoringPanel({
    super.key,
    required this.profile,
    required this.confirmedDoses,
    required this.totalScheduledDoses,
    required this.isCaregiver,
  });

  final UserProfile profile;
  final int confirmedDoses;
  final int totalScheduledDoses;
  final bool isCaregiver;

  @override
  State<TreatmentMonitoringPanel> createState() =>
      _TreatmentMonitoringPanelState();
}

class _TreatmentMonitoringPanelState extends State<TreatmentMonitoringPanel> {
  bool _initializationRequested = false;
  Object? _initializationError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initializationRequested ||
        widget.profile.isDemo ||
        widget.profile.treatmentStartedAt == null) {
      return;
    }
    _initializationRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_initializeMonitoring());
    });
  }

  Future<void> _initializeMonitoring() async {
    try {
      await context.read<TreatmentMonitoringRepository>().ensureMonitoring(
        widget.profile,
        repairPendingSchedule: !widget.isCaregiver,
      );
    } catch (error) {
      if (mounted) setState(() => _initializationError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.read<TreatmentMonitoringRepository>();
    return StreamBuilder<TreatmentMonitoring?>(
      stream: repository.treatmentForPatient(widget.profile.id),
      builder: (context, treatmentSnapshot) {
        if (treatmentSnapshot.hasError) {
          return AsyncErrorView(error: treatmentSnapshot.error);
        }
        if (!treatmentSnapshot.hasData) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: AppLoadingView(message: 'Memuat monitoring terapi…'),
            ),
          );
        }
        final treatment = treatmentSnapshot.data;
        if (treatment == null) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: widget.profile.isDemo
                  ? const Text('Data monitoring terapi belum tersedia.')
                  : _initializationError == null
                  ? const AppLoadingView(
                      message: 'Menyiapkan monitoring terapi…',
                    )
                  : Column(
                      children: [
                        const Text('Monitoring terapi belum dapat disiapkan.'),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () {
                            setState(() => _initializationError = null);
                            unawaited(_initializeMonitoring());
                          },
                          child: const Text('Coba lagi'),
                        ),
                      ],
                    ),
            ),
          );
        }
        return StreamBuilder<List<BtaExamination>>(
          stream: repository.examinationsForPatient(widget.profile.id),
          builder: (context, examinationSnapshot) {
            if (examinationSnapshot.hasError) {
              return AsyncErrorView(error: examinationSnapshot.error);
            }
            if (!examinationSnapshot.hasData) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: AppLoadingView(message: 'Memuat pemeriksaan BTA…'),
                ),
              );
            }
            final examinations = examinationSnapshot.data!;
            final decision = const TreatmentOutcomeDecisionTree().evaluate(
              treatment: treatment,
              examinations: examinations,
            );
            return _MonitoringContent(
              profile: widget.profile,
              treatment: treatment,
              examinations: examinations,
              decision: decision,
              confirmedDoses: widget.confirmedDoses,
              totalScheduledDoses: widget.totalScheduledDoses,
              isCaregiver: widget.isCaregiver,
            );
          },
        );
      },
    );
  }
}

class TreatmentMonitoringCompactSummary extends StatefulWidget {
  const TreatmentMonitoringCompactSummary({
    super.key,
    required this.profile,
    required this.confirmedDoses,
    required this.totalScheduledDoses,
  });

  final UserProfile profile;
  final int confirmedDoses;
  final int totalScheduledDoses;

  @override
  State<TreatmentMonitoringCompactSummary> createState() =>
      _TreatmentMonitoringCompactSummaryState();
}

class _TreatmentMonitoringCompactSummaryState
    extends State<TreatmentMonitoringCompactSummary> {
  bool _initializationRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initializationRequested ||
        widget.profile.isDemo ||
        widget.profile.treatmentStartedAt == null) {
      return;
    }
    _initializationRequested = true;
    unawaited(
      context
          .read<TreatmentMonitoringRepository>()
          .ensureMonitoring(widget.profile)
          .catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.read<TreatmentMonitoringRepository>();
    return StreamBuilder<TreatmentMonitoring?>(
      stream: repository.treatmentForPatient(widget.profile.id),
      builder: (context, treatmentSnapshot) {
        if (treatmentSnapshot.hasError) {
          return const Text('Ringkasan monitoring belum dapat dimuat.');
        }
        final treatment = treatmentSnapshot.data;
        if (treatment == null) return const SizedBox.shrink();
        return StreamBuilder<List<BtaExamination>>(
          stream: repository.examinationsForPatient(widget.profile.id),
          builder: (context, examSnapshot) {
            if (examSnapshot.hasError) {
              return const Text('Ringkasan BTA belum dapat dimuat.');
            }
            final exams = examSnapshot.data ?? const <BtaExamination>[];
            final decision = const TreatmentOutcomeDecisionTree().evaluate(
              treatment: treatment,
              examinations: exams,
            );
            final adherenceDecision = const AdherenceDecisionTree().evaluate(
              confirmedDoses: widget.confirmedDoses,
              totalScheduledDoses: widget.totalScheduledDoses,
            );
            final now = DateTime.now();
            final latest = _latestResult(exams);
            final progress = TreatmentPlan.progress(
              group: widget.profile.treatmentGroup,
              treatmentStartedAt: treatment.treatmentStartDate,
              now: now,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(height: 24),
                Text(
                  'Terapi bulan ${_currentMonth(treatment, now)} dari 6',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  'Mulai terapi: ${_date(context, treatment.treatmentStartDate)}',
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: progress.clamp(0, 1)),
                const SizedBox(height: 8),
                Text(
                  'Kepatuhan: ${adherenceDecision.formattedPercentage}% · '
                  '${adherenceDecision.displayLabel}',
                ),
                Text(
                  'BTA terbaru: ${latest?.result?.label ?? 'Belum tersedia'}',
                ),
                const SizedBox(height: 6),
                Text(
                  'Hasil terapi: ${_outcomeDisplayLabel(decision.outcome)}',
                  style: TextStyle(
                    color: _outcomeColor(decision.outcome),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (decision.outcome == TreatmentOutcome.treatmentInProgress)
                  const Text(
                    'Hasil akhir belum tersedia karena terapi masih berjalan.',
                    style: TextStyle(fontSize: 12),
                  ),
                Text(
                  'Klasifikasi kepatuhan: ${adherenceDecision.displayLabel}',
                  style: TextStyle(
                    color: _adherenceColor(adherenceDecision.classification),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _MonitoringContent extends StatelessWidget {
  const _MonitoringContent({
    required this.profile,
    required this.treatment,
    required this.examinations,
    required this.decision,
    required this.confirmedDoses,
    required this.totalScheduledDoses,
    required this.isCaregiver,
  });

  final UserProfile profile;
  final TreatmentMonitoring treatment;
  final List<BtaExamination> examinations;
  final TreatmentOutcomeDecision decision;
  final int confirmedDoses;
  final int totalScheduledDoses;
  final bool isCaregiver;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final latest = _latestResult(examinations);
    final progress = TreatmentPlan.progress(
      group: profile.treatmentGroup,
      treatmentStartedAt: treatment.treatmentStartDate,
      now: now,
    );
    final warnings = isCaregiver
        ? _warnings(examinations, decision, now)
        : const <String>[];
    final adherenceDecision = const AdherenceDecisionTree().evaluate(
      confirmedDoses: confirmedDoses,
      totalScheduledDoses: totalScheduledDoses,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (profile.isDemo)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'RINGKASAN TERAPI',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(
                    label: 'Tanggal mulai',
                    value: _date(context, treatment.treatmentStartDate),
                  ),
                  _InfoRow(
                    label: 'Perkiraan selesai',
                    value: _date(context, treatment.expectedCompletionDate),
                  ),
                  _InfoRow(label: 'Status', value: treatment.status.label),
                  _InfoRow(
                    label: 'Hasil terapi',
                    value: _outcomeDisplayLabel(decision.outcome),
                  ),
                  _InfoRow(
                    label: 'Konversi BTA',
                    value: decision.conversionDetected
                        ? 'Terdeteksi'
                        : 'Belum terdeteksi',
                  ),
                  _InfoRow(
                    label: 'Reversi BTA',
                    value: decision.confirmedReversal
                        ? 'Terkonfirmasi'
                        : decision.possibleReversal
                        ? 'Dugaan, perlu konfirmasi'
                        : 'Tidak terdeteksi',
                  ),
                ],
              ),
            ),
          ),
        if (isCaregiver)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'PERKEMBANGAN TERAPI',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                      ),
                      if (isCaregiver && !profile.isDemo)
                        IconButton(
                          tooltip: 'Perbarui status terapi',
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => TreatmentStatusFormScreen(
                                treatment: treatment,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.edit_note_rounded),
                        ),
                    ],
                  ),
                  Text(
                    'Bulan ${_currentMonth(treatment, now)} dari sekitar 6 bulan',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 9),
                  LinearProgressIndicator(value: progress.clamp(0, 1)),
                  const SizedBox(height: 14),
                  _InfoRow(
                    label: 'BTA terbaru',
                    value: latest?.result?.label ?? 'Belum tersedia',
                  ),
                  const Divider(height: 24),
                  _DecisionTreeResultBox(
                    title: 'HASIL TERAPI',
                    primaryValue: _outcomeDisplayLabel(decision.outcome),
                    color: _outcomeColor(decision.outcome),
                    determinedBy: 'TreatmentOutcomeDecisionTree',
                    supportingText:
                        decision.outcome == TreatmentOutcome.treatmentInProgress
                        ? latest == null
                              ? 'Belum ada hasil akhir. Terapi masih berjalan dan '
                                    'hasil pemeriksaan BTA belum dicatat.'
                              : 'Belum ada hasil akhir. Terapi masih berjalan; '
                                    'hasil akan diperbarui setelah data terapi lengkap.'
                        : 'Hasil akhir dihitung dari status terapi dan riwayat BTA.',
                  ),
                  const SizedBox(height: 10),
                  _DecisionTreeResultBox(
                    title: 'KEPATUHAN MINUM OBAT',
                    primaryValue:
                        '${adherenceDecision.formattedPercentage}% · '
                        '${adherenceDecision.displayLabel}',
                    color: _adherenceColor(adherenceDecision.classification),
                    determinedBy: 'AdherenceDecisionTree',
                    supportingText: totalScheduledDoses == 0
                        ? 'Belum ada dosis terjadwal yang sudah jatuh tempo. '
                              'Persentase akan dihitung setelah jadwal dimulai.'
                        : 'Dihitung dari $confirmedDoses konfirmasi dari '
                              '$totalScheduledDoses dosis terjadwal.',
                  ),
                  if (decision.possibleReversal &&
                      !decision.confirmedReversal) ...[
                    const SizedBox(height: 12),
                    const _WarningTile(
                      message:
                          'Ada kemungkinan reversi bakteriologis. Pemeriksaan '
                          'ulang atau konfirmasi diperlukan.',
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            color: const Color(0xFFFFF4E5),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Perlu perhatian pengawas',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  ...warnings.map((warning) => _WarningTile(message: warning)),
                ],
              ),
            ),
          ),
        ],
        if (isCaregiver) ...[
          const SizedBox(height: 12),
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.account_tree_outlined),
              title: const Text(
                'Penjelasan hasil terapi',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                'Konversi: ${decision.conversionDetected ? 'TERDETEKSI' : 'TIDAK TERDETEKSI'} '
                '• Reversi: ${decision.confirmedReversal
                    ? 'TERKONFIRMASI'
                    : decision.possibleReversal
                    ? 'MUNGKIN'
                    : 'TIDAK TERDETEKSI'}',
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: decision.reasoningPath
                        .map(
                          (line) => Padding(
                            padding: const EdgeInsets.only(top: 7),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.chevron_right, size: 18),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(_localizedDecisionLine(line)),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: const Text(
                'Penjelasan klasifikasi kepatuhan',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                '${adherenceDecision.formattedPercentage}% · '
                '${adherenceDecision.displayLabel}',
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: adherenceDecision.reasoningPath
                        .map(
                          (line) => Padding(
                            padding: const EdgeInsets.only(top: 7),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.chevron_right, size: 18),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(_localizedDecisionLine(line)),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Text(
                'Hasil Pemeriksaan BTA',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (examinations.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: _EmptyExaminationMessage(isCaregiver: isCaregiver),
            ),
          )
        else
          ...examinations.map(
            (exam) => Card(
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(16, 9, 10, 9),
                leading: CircleAvatar(
                  backgroundColor: _resultColor(
                    exam.result,
                  ).withValues(alpha: .12),
                  child: Icon(
                    exam.hasResult
                        ? Icons.science_rounded
                        : Icons.event_outlined,
                    color: _resultColor(exam.result),
                  ),
                ),
                title: Text(
                  exam.type.label,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(_examinationDetails(context, exam)),
                isThreeLine: true,
                trailing: isCaregiver && !profile.isDemo
                    ? IconButton(
                        tooltip: 'Isi hasil pemeriksaan',
                        onPressed: () =>
                            _openExaminationForm(context, examination: exam),
                        icon: const Icon(Icons.edit_outlined),
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }

  void _openExaminationForm(
    BuildContext context, {
    required BtaExamination examination,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => BtaExaminationFormScreen(
          patientId: profile.id,
          examination: examination,
        ),
      ),
    );
  }
}

class _DecisionTreeResultBox extends StatelessWidget {
  const _DecisionTreeResultBox({
    required this.title,
    required this.primaryValue,
    required this.color,
    required this.determinedBy,
    required this.supportingText,
  });

  final String title;
  final String primaryValue;
  final Color color;
  final String determinedBy;
  final String supportingText;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: color.withValues(alpha: .25)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: color,
            fontSize: 11,
            letterSpacing: .7,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          primaryValue,
          style: TextStyle(
            color: color,
            fontSize: 19,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 5),
        Text(supportingText),
        const SizedBox(height: 5),
        Text(
          'Ditentukan oleh $determinedBy',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
}

class _EmptyExaminationMessage extends StatelessWidget {
  const _EmptyExaminationMessage({required this.isCaregiver});

  final bool isCaregiver;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Icon(Icons.biotech_outlined, size: 38, color: colors.primary),
        const SizedBox(height: 10),
        const Text(
          'Belum ada pemeriksaan BTA',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 5),
        Text(
          isCaregiver
              ? 'Empat jadwal monitoring dibuat otomatis dari tanggal mulai terapi. '
                    'Tekan Coba lagi jika data belum muncul.'
              : 'Empat jadwal monitoring akan dibuat otomatis dari tanggal mulai terapi.',
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class _WarningTile extends StatelessWidget {
  const _WarningTile({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.warning_amber_rounded,
          size: 19,
          color: Color(0xFFC77700),
        ),
        const SizedBox(width: 7),
        Expanded(child: Text(message)),
      ],
    ),
  );
}

List<String> _warnings(
  List<BtaExamination> examinations,
  TreatmentOutcomeDecision decision,
  DateTime now,
) {
  final warnings = <String>[];
  for (final exam in examinations.where((item) => !item.hasResult)) {
    final windowStart = TreatmentPlan.dateOnly(exam.scheduledDate);
    final windowEnd = TreatmentPlan.addMonths(windowStart, 1);
    final today = TreatmentPlan.dateOnly(now);
    if (!today.isBefore(windowEnd)) {
      warnings.add(
        '${exam.type.label} sudah melewati rentang bulan pemeriksaan dan hasilnya belum dicatat.',
      );
    } else if (!today.isBefore(windowStart)) {
      warnings.add(
        '${exam.type.label} sedang berada dalam rentang pemeriksaan bulan ini.',
      );
    }
  }
  if (decision.possibleReversal && !decision.confirmedReversal) {
    warnings.add(
      'Ada hasil positif setelah konversi. Pemeriksaan ulang diperlukan untuk '
      'mengonfirmasi kemungkinan reversi.',
    );
  }
  final followUpPositive = examinations.any(
    (exam) =>
        exam.type != BtaExaminationType.initial &&
        exam.type != BtaExaminationType.confirmation &&
        exam.result == BtaResult.positive,
  );
  if (followUpPositive && !decision.confirmedFailure) {
    warnings.add(
      'Ada kemungkinan kegagalan terapi. Diperlukan tinjauan medis dan '
      'pemeriksaan konfirmasi.',
    );
  }
  if (decision.confirmedReversal) {
    warnings.add('Reversi bakteriologis terkonfirmasi.');
  }
  if (decision.confirmedFailure) {
    warnings.add('Kegagalan terapi terkonfirmasi.');
  }
  return warnings.toSet().toList(growable: false);
}

BtaExamination? _latestResult(List<BtaExamination> examinations) {
  final completed = examinations.where((item) => item.hasResult).toList()
    ..sort(
      (a, b) => (b.examinationDate ?? b.scheduledDate).compareTo(
        a.examinationDate ?? a.scheduledDate,
      ),
    );
  return completed.isEmpty ? null : completed.first;
}

String _examinationDetails(BuildContext context, BtaExamination exam) {
  final lines = <String>['Status: ${exam.result?.label ?? 'BELUM DIPERIKSA'}'];
  if (exam.examinationDate != null) {
    lines.add('Diperiksa: ${_date(context, exam.examinationDate!)}');
  }
  if (exam.notes.trim().isNotEmpty) {
    lines.add('Catatan: ${exam.notes.trim()}');
  }
  return lines.join('\n');
}

int _currentMonth(TreatmentMonitoring treatment, DateTime now) {
  if (now.isBefore(treatment.treatmentStartDate)) return 0;
  final months =
      (now.year - treatment.treatmentStartDate.year) * 12 +
      now.month -
      treatment.treatmentStartDate.month;
  return (months + 1).clamp(1, 6).toInt();
}

String _date(BuildContext context, DateTime value) =>
    MaterialLocalizations.of(context).formatMediumDate(value);

String _outcomeDisplayLabel(TreatmentOutcome outcome) => switch (outcome) {
  TreatmentOutcome.cured => 'SEMBUH',
  TreatmentOutcome.treatmentCompleted => 'PENGOBATAN LENGKAP',
  TreatmentOutcome.failed => 'GAGAL',
  TreatmentOutcome.treatmentInProgress => 'DALAM PENGOBATAN',
};

String _localizedDecisionLine(String value) {
  var result = value
      .replaceFirst('Treatment completed?', 'Terapi selesai?')
      .replaceFirst(
        'Confirmed treatment failure?',
        'Kegagalan terapi terkonfirmasi?',
      )
      .replaceFirst('Initial BTA positive?', 'BTA awal positif?')
      .replaceFirst('BTA conversion detected?', 'Konversi BTA terdeteksi?')
      .replaceFirst(
        'Confirmed bacteriological reversal?',
        'Reversi bakteriologis terkonfirmasi?',
      )
      .replaceFirst('Final BTA negative?', 'BTA akhir negatif?')
      .replaceFirst('Final classification:', 'Klasifikasi akhir:')
      .replaceFirst('Adherence Percentage:', 'Persentase kepatuhan:')
      .replaceFirst('Node 1:', 'Tahap 1:')
      .replaceFirst('Node 2:', 'Tahap 2:')
      .replaceFirst('Is adherence', 'Apakah kepatuhan')
      .replaceFirst('Final Result:', 'Hasil akhir:')
      .replaceAll('YES', 'YA')
      .replaceAll('NO', 'TIDAK');
  for (final outcome in TreatmentOutcome.values) {
    result = result.replaceAll(outcome.label, _outcomeDisplayLabel(outcome));
  }
  return result;
}

Color _outcomeColor(TreatmentOutcome outcome) => switch (outcome) {
  TreatmentOutcome.cured => const Color(0xFF228B64),
  TreatmentOutcome.treatmentCompleted => const Color(0xFF176B8A),
  TreatmentOutcome.failed => const Color(0xFFD24F4A),
  TreatmentOutcome.treatmentInProgress => const Color(0xFFE0A11B),
};

Color _adherenceColor(AdherenceClassification classification) =>
    switch (classification) {
      AdherenceClassification.veryHigh => const Color(0xFF228B64),
      AdherenceClassification.moderate => const Color(0xFFE0A11B),
      AdherenceClassification.low => const Color(0xFFD24F4A),
    };

Color _resultColor(BtaResult? result) => switch (result) {
  BtaResult.negative => const Color(0xFF228B64),
  BtaResult.positive => const Color(0xFFD24F4A),
  BtaResult.tdl || BtaResult.notExamined => const Color(0xFFE0A11B),
  null => const Color(0xFF176B8A),
};
