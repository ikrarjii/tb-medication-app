import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_notification.dart';
import '../models/medicine.dart';
import '../models/medication_timing.dart';
import '../models/patient_pairing.dart';
import '../models/treatment_plan.dart';
import '../models/user_profile.dart';
import '../services/auth_service.dart';
import '../services/medicine_repository.dart';
import '../widgets/account_profile_page.dart';
import '../widgets/adherence_indicator.dart';
import '../widgets/app_state_view.dart';
import '../widgets/async_error_view.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/treatment_monitoring_panel.dart';
import 'pmo_medication_settings_screen.dart';

class CaregiverHomeScreen extends StatefulWidget {
  const CaregiverHomeScreen({super.key});

  @override
  State<CaregiverHomeScreen> createState() => _CaregiverHomeScreenState();
}

class _CaregiverHomeScreenState extends State<CaregiverHomeScreen> {
  int _index = 0;
  static const _titles = ['Pasien Terhubung', 'Notifikasi', 'Profil'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(_titles[_index]),
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          _CaregiverPatientsPage(),
          _CaregiverNotificationsPage(),
          AccountProfilePage(isPatient: false),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.people_outline_rounded),
            selectedIcon: Icon(Icons.people_rounded),
            label: 'Beranda',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications_rounded),
            label: 'Notifikasi',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profil',
          ),
        ],
      ),
    );
  }
}

class _CaregiverPatientsPage extends StatelessWidget {
  const _CaregiverPatientsPage();

  @override
  Widget build(BuildContext context) {
    final caregiverId = context.read<AuthService>().user!.uid;
    final repository = context.read<MedicineRepository>();
    return StreamBuilder<UserProfile>(
      stream: repository.profile(caregiverId),
      builder: (context, profileSnapshot) {
        if (profileSnapshot.hasError) {
          return AsyncErrorView(error: profileSnapshot.error);
        }
        if (!profileSnapshot.hasData) {
          return const AppLoadingView(message: 'Memuat profil pengawas...');
        }
        return StreamBuilder<List<PatientPairing>>(
          stream: repository.linkedPatients(caregiverId),
          builder: (context, snapshot) {
            if (snapshot.hasError) return AsyncErrorView(error: snapshot.error);
            if (!snapshot.hasData) {
              return const AppLoadingView(message: 'Memuat pasien terhubung…');
            }
            final patients = snapshot.data!;
            return LayoutBuilder(
              builder: (context, constraints) {
                final contentWidth = constraints.maxWidth > 1000
                    ? 960.0
                    : constraints.maxWidth;
                final cardWidth = contentWidth >= 720
                    ? (contentWidth - 52) / 2
                    : contentWidth - 40;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  children: [
                    Center(
                      child: SizedBox(
                        width: contentWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Halo, ${_firstName(profileSnapshot.data!.fullName)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Pantau jadwal obat pasien secara langsung.',
                            ),
                            const SizedBox(height: 22),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Pasien Anda',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                ),
                                FilledButton.tonalIcon(
                                  onPressed: () => _linkPatient(
                                    context,
                                    caregiverId,
                                    repository,
                                  ),
                                  icon: const Icon(
                                    Icons.person_add_alt_1_rounded,
                                  ),
                                  label: const Text('Hubungkan'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (patients.isEmpty)
                              _EmptyPatientsCard(
                                onLink: () => _linkPatient(
                                  context,
                                  caregiverId,
                                  repository,
                                ),
                              )
                            else
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: patients
                                    .map(
                                      (pairing) => SizedBox(
                                        width: cardWidth,
                                        child: _ConnectedPatientCard(
                                          pairing: pairing,
                                          repository: repository,
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _linkPatient(
    BuildContext context,
    String caregiverId,
    MedicineRepository repository,
  ) async {
    var enteredCode = '';
    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hubungkan pasien'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Masukkan kode 8 karakter dari profil pasien.'),
            const SizedBox(height: 14),
            TextField(
              autofocus: true,
              onChanged: (value) => enteredCode = value,
              textCapitalization: TextCapitalization.characters,
              maxLength: 8,
              decoration: const InputDecoration(
                labelText: 'Kode pasien',
                prefixIcon: Icon(Icons.key_rounded),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, enteredCode),
            child: const Text('Hubungkan'),
          ),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) return;
    try {
      await repository.linkPatientByCode(
        caregiverId: caregiverId,
        patientCode: code,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pasien berhasil dihubungkan.')),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_errorText(error))));
      }
    }
  }
}

class _EmptyPatientsCard extends StatelessWidget {
  const _EmptyPatientsCard({required this.onLink});
  final VoidCallback onLink;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          Icon(
            Icons.group_add_outlined,
            size: 44,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          const Text(
            'Belum ada pasien terhubung',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          const SizedBox(height: 5),
          const Text(
            'Minta kode pasien lalu hubungkan akunnya di sini.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: onLink,
            child: const Text('Masukkan kode pasien'),
          ),
        ],
      ),
    ),
  );
}

class _ConnectedPatientCard extends StatelessWidget {
  const _ConnectedPatientCard({
    required this.pairing,
    required this.repository,
  });
  final PatientPairing pairing;
  final MedicineRepository repository;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserProfile>(
      stream: repository.profile(pairing.patientId),
      builder: (context, profileSnapshot) {
        if (profileSnapshot.hasError) {
          return Card(child: AsyncErrorView(error: profileSnapshot.error));
        }
        if (!profileSnapshot.hasData) {
          return const Card(
            child: SizedBox(
              height: 190,
              child: AppLoadingView(message: 'Memuat data pasien…'),
            ),
          );
        }
        final profile = profileSnapshot.data!;
        return StreamBuilder<List<Medicine>>(
          stream: repository.medicinesForPatient(pairing.patientId),
          builder: (context, medicineSnapshot) {
            if (medicineSnapshot.hasError) {
              return Card(child: AsyncErrorView(error: medicineSnapshot.error));
            }
            if (!medicineSnapshot.hasData) {
              return const Card(
                child: AppLoadingView(message: 'Memuat jadwal pasien…'),
              );
            }
            final medicines = medicineSnapshot.data!;
            final now = DateTime.now();
            final scheduledForAdherence = medicines
                .where(
                  (medicine) =>
                      medicine.scheduledAt != null &&
                      !medicine.scheduledAt!.isAfter(now),
                )
                .toList(growable: false);
            final confirmedDoses = scheduledForAdherence
                .where((medicine) => medicine.isTaken)
                .length;
            final today = medicines
                .where((m) => _sameDay(m.scheduledAt, now))
                .toList();
            final alerts = today.where(_needsAttention).length;
            final last = medicines.where((m) => m.takenAt != null).toList()
              ..sort((a, b) => b.takenAt!.compareTo(a.takenAt!));
            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        PatientDetailScreen(patientId: pairing.patientId),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          ProfileAvatar(
                            name: profile.fullName,
                            photoUrl: profile.photoUrl,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  profile.fullName,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                Text(
                                  '${today.where(_isCompleted).length}/${today.length} dosis selesai hari ini',
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                      const SizedBox(height: 14),
                      AdherenceIndicator(
                        confirmedDoses: confirmedDoses,
                        totalScheduledDoses: scheduledForAdherence.length,
                        compact: true,
                      ),
                      TreatmentMonitoringCompactSummary(
                        profile: profile,
                        confirmedDoses: confirmedDoses,
                        totalScheduledDoses: scheduledForAdherence.length,
                      ),
                      const Divider(height: 24),
                      Row(
                        children: [
                          Icon(
                            alerts == 0
                                ? Icons.check_circle_outline_rounded
                                : Icons.warning_amber_rounded,
                            color: alerts == 0
                                ? const Color(0xFF228B64)
                                : const Color(0xFFD24F4A),
                            size: 19,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              alerts == 0
                                  ? 'Status hari ini baik'
                                  : '$alerts jadwal perlu perhatian',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        last.isEmpty
                            ? 'Belum ada obat yang diminum'
                            : 'Terakhir: ${_dateTime(context, last.first.takenAt)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _CaregiverNotificationsPage extends StatelessWidget {
  const _CaregiverNotificationsPage();

  @override
  Widget build(BuildContext context) {
    final userId = context.read<AuthService>().user!.uid;
    final repository = context.read<MedicineRepository>();
    return StreamBuilder<List<AppNotification>>(
      stream: repository.notificationsFor(userId),
      builder: (context, snapshot) {
        if (snapshot.hasError) return AsyncErrorView(error: snapshot.error);
        if (!snapshot.hasData) {
          return const AppLoadingView(message: 'Memuat notifikasi…');
        }
        final notifications = snapshot.data!;
        final unread = notifications.where((item) => !item.isRead).length;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Row(
              children: [
                Expanded(child: Text('$unread notifikasi belum dibaca')),
                if (unread > 0)
                  TextButton(
                    onPressed: () =>
                        repository.markAllNotificationsRead(userId),
                    child: const Text('Tandai semua'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (notifications.isEmpty)
              const Card(
                child: AppEmptyState(
                  icon: Icons.notifications_none_rounded,
                  title: 'Belum ada notifikasi',
                  message:
                      'Pembaruan jadwal, dosis terlewat, dan konfirmasi obat '
                      'pasien akan muncul di sini.',
                ),
              )
            else
              ...notifications.map(
                (item) => Card(
                  color: item.isRead
                      ? Colors.white
                      : Theme.of(context).colorScheme.primaryContainer,
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(14),
                    leading: CircleAvatar(
                      backgroundColor: _notificationColor(
                        item.type,
                      ).withValues(alpha: .14),
                      child: Icon(
                        _notificationIcon(item.type),
                        color: _notificationColor(item.type),
                      ),
                    ),
                    title: Text(
                      item.title,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      '${item.message}\n${_dateTime(context, item.createdAt)}',
                    ),
                    isThreeLine: true,
                    onTap: () {
                      if (!item.isRead) {
                        repository.markNotificationRead(item.id);
                      }
                      final patientId = item.patientId;
                      if (patientId != null && patientId != userId) {
                        Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                PatientDetailScreen(patientId: patientId),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class PatientDetailScreen extends StatelessWidget {
  const PatientDetailScreen({super.key, required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context) {
    final repository = context.read<MedicineRepository>();
    final caregiverId = context.read<AuthService>().user!.uid;
    return StreamBuilder<UserProfile>(
      stream: repository.profile(patientId),
      builder: (context, profileSnapshot) {
        if (profileSnapshot.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: AsyncErrorView(error: profileSnapshot.error),
          );
        }
        if (!profileSnapshot.hasData) {
          return const Scaffold(
            body: AppLoadingView(message: 'Memuat detail pasien…'),
          );
        }
        final profile = profileSnapshot.data!;
        return Scaffold(
          appBar: AppBar(
            title: Text(profile.fullName),
            actions: [
              IconButton(
                tooltip: 'Atur jadwal minum obat',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        PmoMedicationSettingsScreen(patientId: patientId),
                  ),
                ),
                icon: const Icon(Icons.settings_rounded),
              ),
              IconButton(
                tooltip: 'Putuskan hubungan',
                onPressed: () =>
                    _confirmUnlink(context, repository, caregiverId, profile),
                icon: const Icon(Icons.link_off_rounded),
              ),
            ],
          ),
          body: StreamBuilder<List<Medicine>>(
            stream: repository.medicinesForPatient(patientId),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return AsyncErrorView(error: snapshot.error);
              }
              if (!snapshot.hasData) {
                return const AppLoadingView(
                  message: 'Memuat jadwal dan riwayat pasien…',
                );
              }
              final all = snapshot.data!;
              final now = DateTime.now();
              final today =
                  all.where((m) => _sameDay(m.scheduledAt, now)).toList()..sort(
                    (a, b) => (a.scheduledAt ?? DateTime(2100)).compareTo(
                      b.scheduledAt ?? DateTime(2100),
                    ),
                  );
              final completed = all.where(_isCompleted).toList();
              final scheduledForAdherence = all
                  .where(
                    (medicine) =>
                        medicine.scheduledAt != null &&
                        !medicine.scheduledAt!.isAfter(now),
                  )
                  .toList(growable: false);
              final confirmedDoses = scheduledForAdherence
                  .where((medicine) => medicine.isTaken)
                  .length;
              final todaySummary = MedicationStatusSummary.fromMedicines(
                today,
                now: now,
              );
              final treatmentStartedAt = profile.treatmentStartedAt;
              final treatmentSummary = treatmentStartedAt == null
                  ? const MedicationStatusSummary()
                  : MedicationStatusSummary.fromMedicines(
                      all,
                      now: now,
                      startsAt: TreatmentPlan.dateOnly(treatmentStartedAt),
                      endsAt: TreatmentPlan.endDate(
                        profile.treatmentGroup,
                        treatmentStartedAt,
                      ),
                    );
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                    children: [
                      Row(
                        children: [
                          ProfileAvatar(
                            name: profile.fullName,
                            photoUrl: profile.photoUrl,
                            radius: 34,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  profile.fullName,
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                Text('Kode ${profile.patientCode ?? '-'}'),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              _TreatmentInfoRow(
                                label: 'Kelompok terapi',
                                value: TreatmentPlan.labelFor(
                                  profile.treatmentGroup,
                                ),
                              ),
                              _TreatmentInfoRow(
                                label: 'Waktu minum obat',
                                value: profile.hasMedicationTime
                                    ? TimeOfDay(
                                        hour: profile.medicationHour!,
                                        minute: profile.medicationMinute!,
                                      ).format(context)
                                    : 'Belum diatur',
                              ),
                              _TreatmentInfoRow(
                                label: 'Batas tepat waktu',
                                value:
                                    '${medicationLateGracePeriod.inMinutes} menit setelah jadwal',
                              ),
                              _TreatmentInfoRow(
                                label: 'Batas terlewat',
                                value:
                                    '${medicationMissedAfter.inHours} jam setelah jadwal',
                              ),
                              const _TreatmentInfoRow(
                                label: 'Hari terapi',
                                value: 'Dihitung otomatis oleh sistem',
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TreatmentMonitoringPanel(
                        profile: profile,
                        confirmedDoses: confirmedDoses,
                        totalScheduledDoses: scheduledForAdherence.length,
                        isCaregiver: true,
                      ),
                      const SizedBox(height: 12),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: AdherenceIndicator(
                            confirmedDoses: confirmedDoses,
                            totalScheduledDoses: scheduledForAdherence.length,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _MedicationStatusSummaryCard(
                        title: 'Status dosis hari ini',
                        subtitle: 'Dihitung dari jadwal hari ini',
                        summary: todaySummary,
                      ),
                      const SizedBox(height: 12),
                      _MedicationStatusSummaryCard(
                        title: 'Rekap terapi 6 bulan',
                        subtitle: treatmentStartedAt == null
                            ? 'Tanggal mulai terapi belum tersedia'
                            : 'Kumulatif sejak tanggal mulai terapi',
                        summary: treatmentSummary,
                      ),
                      const SizedBox(height: 20),
                      _SectionTitle(
                        title: 'Jadwal hari ini',
                        count: today.length,
                      ),
                      const SizedBox(height: 8),
                      if (today.isEmpty)
                        const _SimpleEmpty(
                          icon: Icons.event_available_outlined,
                          title: 'Tidak ada jadwal hari ini',
                          message:
                              'Hari ini bukan hari minum obat pasien. Periksa '
                              'pengaturan waktu jika jadwal seharusnya tersedia.',
                        )
                      else
                        ...today.map(
                          (medicine) =>
                              _CaregiverMedicineTile(medicine: medicine),
                        ),
                      const SizedBox(height: 20),
                      _SectionTitle(
                        title: 'Riwayat pengobatan',
                        count: completed.length,
                      ),
                      const SizedBox(height: 8),
                      if (completed.isEmpty)
                        const _SimpleEmpty(
                          icon: Icons.history_rounded,
                          title: 'Riwayat obat masih kosong',
                          message:
                              'Catatan akan muncul setelah pasien mengonfirmasi '
                              'dosis sebagai diminum atau tidak diminum.',
                        )
                      else
                        ...completed
                            .take(30)
                            .map(
                              (medicine) => Card(
                                child: ListTile(
                                  leading: Icon(
                                    medicine.isTaken
                                        ? Icons.check_circle_rounded
                                        : Icons.cancel_rounded,
                                    color: medicine.isLateConfirmation
                                        ? const Color(0xFFE0A11B)
                                        : medicine.isTaken
                                        ? const Color(0xFF228B64)
                                        : const Color(0xFFD24F4A),
                                  ),
                                  title: Text(
                                    medicine.displayName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: .7,
                                    ),
                                  ),
                                  subtitle: Text(
                                    medicine.isTaken
                                        ? 'Jadwal ${_dateTime(context, medicine.scheduledAt)}\nDiminum ${_dateTime(context, medicine.takenAt)}'
                                        : 'Jadwal ${_dateTime(context, medicine.scheduledAt)}\nTidak diminum',
                                  ),
                                  isThreeLine: true,
                                  trailing: Text(
                                    medicine.displayStatus,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: () async {
                          await repository.sendReminder(
                            caregiverId: caregiverId,
                            patientId: patientId,
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Pengingat terkirim.'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.notifications_active_outlined),
                        label: const Text('Kirim pengingat sekarang'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _confirmUnlink(
    BuildContext context,
    MedicineRepository repository,
    String caregiverId,
    UserProfile profile,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Putuskan hubungan?'),
        content: Text(
          'Anda tidak akan dapat melihat data ${profile.fullName} lagi.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Putuskan'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await repository.unlinkPatient(
      caregiverId: caregiverId,
      patientId: patientId,
    );
    if (context.mounted) Navigator.pop(context);
  }
}

class _CaregiverMedicineTile extends StatelessWidget {
  const _CaregiverMedicineTile({required this.medicine});
  final Medicine medicine;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      leading: const CircleAvatar(child: Icon(Icons.medication_rounded)),
      title: Text(
        medicine.displayName,
        style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: .7),
      ),
      subtitle: Text(
        '${medicine.dosage?.isNotEmpty == true ? medicine.dosage : 'Dosis belum tercatat'} · ${_time(context, medicine.scheduledAt)}\n${_effectiveStatus(medicine)}${medicine.takenAt == null ? '' : ' · Diminum ${_time(context, medicine.takenAt)}'}',
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.lock_outline_rounded),
    ),
  );
}

class _TreatmentInfoRow extends StatelessWidget {
  const _TreatmentInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
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

class _StatusMetric extends StatelessWidget {
  const _StatusMetric({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label, $value',
    child: Column(
      children: [
        Text(
          '$value',
          style: TextStyle(
            color: color,
            fontSize: 24,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _MedicationStatusSummaryCard extends StatelessWidget {
  const _MedicationStatusSummaryCard({
    required this.title,
    required this.subtitle,
    required this.summary,
  });

  final String title;
  final String subtitle;
  final MedicationStatusSummary summary;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _StatusMetric(
                  label: 'Tepat waktu',
                  value: summary.onTime,
                  color: const Color(0xFF228B64),
                ),
              ),
              Expanded(
                child: _StatusMetric(
                  label: 'Terlambat',
                  value: summary.late,
                  color: const Color(0xFFE0A11B),
                ),
              ),
              Expanded(
                child: _StatusMetric(
                  label: 'Terlewat',
                  value: summary.missed,
                  color: const Color(0xFFD24F4A),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.count});
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
      ),
      Chip(label: Text('$count')),
    ],
  );
}

class _SimpleEmpty extends StatelessWidget {
  const _SimpleEmpty({
    required this.title,
    required this.message,
    required this.icon,
  });
  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
    child: AppEmptyState(
      title: title,
      message: message,
      icon: icon,
      compact: true,
    ),
  );
}

bool _sameDay(DateTime? a, DateTime? b) =>
    a != null &&
    b != null &&
    a.year == b.year &&
    a.month == b.month &&
    a.day == b.day;
bool _isCompleted(Medicine medicine) =>
    medicine.isTaken || medicine.status == 'missed';
bool _needsAttention(Medicine medicine) =>
    medicine.status == 'missed' ||
    medicine.isLateConfirmation ||
    (medicine.status == 'pending' &&
        (medicine.scheduledAt?.isBefore(DateTime.now()) ?? false));
String _effectiveStatus(Medicine medicine) {
  final scheduledAt = medicine.scheduledAt;
  if (medicine.status != 'pending' || scheduledAt == null) {
    return medicine.displayStatus;
  }
  final now = DateTime.now();
  if (hasMedicationMissedDeadlinePassed(scheduledAt: scheduledAt, now: now)) {
    return 'Terlewat';
  }
  if (isMedicationLate(scheduledAt: scheduledAt, respondedAt: now)) {
    return 'Terlambat dikonfirmasi';
  }
  return !scheduledAt.isAfter(now) ? 'Waktunya minum' : medicine.displayStatus;
}

String _firstName(String name) =>
    name.trim().isEmpty ? 'Sobat' : name.trim().split(RegExp(r'\s+')).first;
String _time(BuildContext _, DateTime? date) => date == null
    ? 'Belum tercatat'
    : formatMedicationTime(date.hour, date.minute);
String _date(BuildContext context, DateTime? date) => date == null
    ? 'Tanggal belum tercatat'
    : MaterialLocalizations.of(context).formatMediumDate(date);
String _dateTime(BuildContext context, DateTime? date) => date == null
    ? 'Belum tercatat'
    : '${_date(context, date)} · ${_time(context, date)}';
String _errorText(Object error) {
  if (error is StateError) return error.message;
  return 'Terjadi kesalahan. Silakan coba lagi.';
}

Color _notificationColor(String type) => switch (type) {
  'taken' => const Color(0xFF228B64),
  'due' || 'triggered' || 'late' || 'taken_late' => const Color(0xFFE0A11B),
  'missed' => const Color(0xFFD24F4A),
  _ => const Color(0xFF07866F),
};
IconData _notificationIcon(String type) => switch (type) {
  'taken' => Icons.check_circle_rounded,
  'due' || 'triggered' => Icons.alarm_rounded,
  'late' || 'taken_late' => Icons.schedule_rounded,
  'missed' => Icons.error_rounded,
  _ => Icons.notifications_rounded,
};
