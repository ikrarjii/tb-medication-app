import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/treatment_monitoring.dart';
import '../services/auth_service.dart';
import '../services/treatment_monitoring_repository.dart';

class TreatmentStatusFormScreen extends StatefulWidget {
  const TreatmentStatusFormScreen({super.key, required this.treatment});

  final TreatmentMonitoring treatment;

  @override
  State<TreatmentStatusFormScreen> createState() =>
      _TreatmentStatusFormScreenState();
}

class _TreatmentStatusFormScreenState extends State<TreatmentStatusFormScreen> {
  late TreatmentStatus _status;
  late ConfirmedFailureType _failureType;
  late DateTime? _actualCompletionDate;
  late final TextEditingController _failureNotesController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _status = widget.treatment.status;
    _failureType = widget.treatment.confirmedFailureType;
    _actualCompletionDate = widget.treatment.actualCompletionDate;
    _failureNotesController = TextEditingController(
      text: widget.treatment.failureNotes,
    );
  }

  @override
  void dispose() {
    _failureNotesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Perbarui Status Terapi')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _StatusInfo(),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<TreatmentStatus>(
                      initialValue: _status,
                      decoration: const InputDecoration(
                        labelText: 'Status penyelesaian terapi',
                        prefixIcon: Icon(Icons.flag_outlined),
                      ),
                      items: TreatmentStatus.values
                          .map(
                            (status) => DropdownMenuItem(
                              value: status,
                              child: Text(status.label),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() {
                                _status = value;
                                if (value == TreatmentStatus.completed) {
                                  _actualCompletionDate ??= DateTime.now();
                                } else {
                                  _actualCompletionDate = null;
                                }
                              });
                            },
                    ),
                    if (_status == TreatmentStatus.completed) ...[
                      const SizedBox(height: 14),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.event_available_outlined),
                        title: const Text('Tanggal terapi selesai'),
                        subtitle: Text(
                          _actualCompletionDate == null
                              ? 'Belum dicatat'
                              : MaterialLocalizations.of(
                                  context,
                                ).formatMediumDate(_actualCompletionDate!),
                        ),
                        trailing: const Icon(Icons.edit_calendar_outlined),
                        onTap: _saving ? null : _pickCompletionDate,
                      ),
                    ],
                    const SizedBox(height: 14),
                    DropdownButtonFormField<ConfirmedFailureType>(
                      initialValue: _failureType,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Kondisi kegagalan terkonfirmasi',
                        prefixIcon: Icon(Icons.warning_amber_rounded),
                      ),
                      items: ConfirmedFailureType.values
                          .map(
                            (type) => DropdownMenuItem(
                              value: type,
                              child: Text(
                                type.label,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _failureType = value);
                              }
                            },
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Pilih kondisi kegagalan hanya setelah ada konfirmasi medis. '
                      'Satu hasil BTA positif tetap harus mengikuti alur pemeriksaan ulang.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _failureNotesController,
                      enabled: !_saving,
                      minLines: 3,
                      maxLines: 6,
                      maxLength: 1000,
                      decoration: const InputDecoration(
                        labelText: 'Catatan klinis / kegagalan',
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
              label: const Text('Simpan dan hitung ulang hasil'),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _pickCompletionDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _actualCompletionDate ?? DateTime.now(),
      firstDate: widget.treatment.treatmentStartDate,
      lastDate: DateTime(2100),
    );
    if (selected != null) setState(() => _actualCompletionDate = selected);
  }

  Future<void> _save() async {
    if (_status == TreatmentStatus.completed && _actualCompletionDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Isi tanggal terapi selesai.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await context.read<TreatmentMonitoringRepository>().updateTreatmentStatus(
        caregiverId: context.read<AuthService>().user!.uid,
        patientId: widget.treatment.patientId,
        status: _status,
        actualCompletionDate: _actualCompletionDate,
        confirmedFailureType: _failureType,
        failureNotes: _failureNotesController.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Status terapi belum dapat diperbarui. Coba lagi.'),
        ),
      );
    }
  }
}

class _StatusInfo extends StatelessWidget {
  const _StatusInfo();

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
          Icon(Icons.account_tree_outlined, color: colors.primary),
          const SizedBox(width: 11),
          const Expanded(
            child: Text(
              'Hasil akhir tidak dipilih secara manual. Sistem menghitungnya '
              'otomatis dari status terapi dan riwayat pemeriksaan BTA.',
            ),
          ),
        ],
      ),
    );
  }
}
