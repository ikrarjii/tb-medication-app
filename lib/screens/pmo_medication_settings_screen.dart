import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/treatment_plan.dart';
import '../models/user_profile.dart';
import '../services/auth_service.dart';
import '../services/medicine_repository.dart';
import '../widgets/async_error_view.dart';
import '../widgets/app_state_view.dart';

class PmoMedicationSettingsScreen extends StatelessWidget {
  const PmoMedicationSettingsScreen({super.key, required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context) {
    final repository = context.read<MedicineRepository>();
    return StreamBuilder<UserProfile>(
      stream: repository.profile(patientId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Pengaturan waktu obat')),
            body: AsyncErrorView(error: snapshot.error),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: AppLoadingView(message: 'Memuat pengaturan waktu obat…'),
          );
        }
        return _MedicationTimeForm(profile: snapshot.data!);
      },
    );
  }
}

class _MedicationTimeForm extends StatefulWidget {
  const _MedicationTimeForm({required this.profile});

  final UserProfile profile;

  @override
  State<_MedicationTimeForm> createState() => _MedicationTimeFormState();
}

class _MedicationTimeFormState extends State<_MedicationTimeForm> {
  late TimeOfDay _time;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _time = TimeOfDay(
      hour: widget.profile.medicationHour ?? 7,
      minute: widget.profile.medicationMinute ?? 0,
    );
  }

  @override
  void didUpdateWidget(covariant _MedicationTimeForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_saving &&
        (oldWidget.profile.medicationHour != widget.profile.medicationHour ||
            oldWidget.profile.medicationMinute !=
                widget.profile.medicationMinute) &&
        widget.profile.hasMedicationTime) {
      _time = TimeOfDay(
        hour: widget.profile.medicationHour!,
        minute: widget.profile.medicationMinute!,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasTreatmentRules =
        widget.profile.treatmentGroup == TreatmentPlan.group1;
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan waktu obat')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            widget.profile.fullName,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(TreatmentPlan.labelFor(widget.profile.treatmentGroup)),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Aturan jadwal otomatis',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  if (hasTreatmentRules) ...[
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.calendar_month_rounded),
                      title: Text('Bulan 1–2'),
                      subtitle: Text('Setiap hari, satu kali sehari'),
                    ),
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.date_range_rounded),
                      title: Text('Bulan 3–6'),
                      subtitle: Text('Senin, Rabu, Jumat; satu kali per hari'),
                    ),
                  ] else
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.info_outline_rounded),
                      title: Text('Aturan pengobatan belum tersedia'),
                      subtitle: Text(
                        'Golongan Lain saat ini hanya dicatat sebagai data profil.',
                      ),
                    ),
                  const Divider(),
                  const Text(
                    'Kelompok terapi dan hari pengobatan ditetapkan otomatis dan tidak dapat diubah oleh PMO.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(18),
              leading: const Icon(Icons.access_time_filled_rounded, size: 32),
              title: const Text('Waktu minum obat'),
              subtitle: Text(
                _time.format(context),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              trailing: const Icon(Icons.edit_rounded),
              onTap: _saving || !hasTreatmentRules ? null : _chooseTime,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _saving || !hasTreatmentRules ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_rounded),
            label: Text(_saving ? 'Membuat jadwal…' : 'Simpan waktu obat'),
          ),
        ],
      ),
    );
  }

  Future<void> _chooseTime() async {
    final selected = await showTimePicker(context: context, initialTime: _time);
    if (selected != null && mounted) setState(() => _time = selected);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<MedicineRepository>().configureMedicationTime(
        caregiverId: context.read<AuthService>().user!.uid,
        patientId: widget.profile.id,
        hour: _time.hour,
        minute: _time.minute,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Waktu tersimpan dan jadwal terapi telah diperbarui.'),
        ),
      );
    } on StateError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gagal menyimpan waktu obat.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
