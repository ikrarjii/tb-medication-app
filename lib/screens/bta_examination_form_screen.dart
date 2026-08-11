import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/bta_examination.dart';
import '../services/auth_service.dart';
import '../services/treatment_monitoring_repository.dart';

class BtaExaminationFormScreen extends StatefulWidget {
  const BtaExaminationFormScreen({
    super.key,
    required this.patientId,
    required this.examination,
  });

  final String patientId;
  final BtaExamination examination;

  @override
  State<BtaExaminationFormScreen> createState() =>
      _BtaExaminationFormScreenState();
}

class _BtaExaminationFormScreenState extends State<BtaExaminationFormScreen> {
  final _formKey = GlobalKey<FormState>();
  BtaResult? _result;
  late final TextEditingController _notesController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existingResult = widget.examination.result;
    _result =
        existingResult == BtaResult.positive ||
            existingResult == BtaResult.negative
        ? existingResult
        : null;
    _notesController = TextEditingController(text: widget.examination.notes);
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Isi Hasil Monitoring BTA')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FormIntro(
                        title: 'Jadwal monitoring otomatis',
                        message:
                            'Jenis dan tanggal monitoring ditentukan oleh sistem dan tidak dapat diubah. '
                            'Pengawas hanya mengisi hasil positif atau negatif.',
                      ),
                      const SizedBox(height: 18),
                      _MonitoringScheduleSummary(
                        examination: widget.examination,
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<BtaResult>(
                        initialValue: _result,
                        decoration: const InputDecoration(
                          labelText: 'Hasil BTA',
                          prefixIcon: Icon(Icons.science_outlined),
                        ),
                        items: const [BtaResult.positive, BtaResult.negative]
                            .map(
                              (result) => DropdownMenuItem(
                                value: result,
                                child: Text(result.label),
                              ),
                            )
                            .toList(growable: false),
                        validator: (value) => value == null
                            ? 'Pilih hasil pemeriksaan BTA.'
                            : null,
                        onChanged: _saving
                            ? null
                            : (value) => setState(() => _result = value),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _notesController,
                        enabled: !_saving,
                        minLines: 3,
                        maxLines: 6,
                        maxLength: 1000,
                        decoration: const InputDecoration(
                          labelText: 'Catatan (opsional)',
                          alignLabelWithHint: true,
                          prefixIcon: Icon(Icons.notes_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Simpan hasil'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await context.read<TreatmentMonitoringRepository>().saveExamination(
        caregiverId: context.read<AuthService>().user!.uid,
        patientId: widget.patientId,
        examinationId: widget.examination.id,
        examinationDate: widget.examination.examinationDate ?? DateTime.now(),
        result: _result!,
        notes: _notesController.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pemeriksaan belum dapat disimpan. Coba lagi.'),
        ),
      );
    }
  }
}

class _MonitoringScheduleSummary extends StatelessWidget {
  const _MonitoringScheduleSummary({required this.examination});

  final BtaExamination examination;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            examination.type.label,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.date_range_rounded, size: 19),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  'Dilakukan kapan saja dalam rentang bulan pemeriksaan ini',
                ),
              ),
              const Icon(Icons.lock_outline_rounded, size: 18),
            ],
          ),
        ],
      ),
    );
  }
}

class _FormIntro extends StatelessWidget {
  const _FormIntro({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: colors.primary),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(message),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
