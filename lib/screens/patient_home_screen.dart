import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/medicine.dart';
import '../models/medication_timing.dart';
import '../models/treatment_plan.dart';
import '../models/user_profile.dart';
import '../services/auth_service.dart';
import '../services/medicine_repository.dart';
import '../services/reminder_service.dart';
import '../widgets/account_profile_page.dart';
import '../widgets/async_error_view.dart';
import '../widgets/adherence_indicator.dart';
import '../widgets/app_state_view.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/treatment_monitoring_panel.dart';

class PatientHomeScreen extends StatefulWidget {
  const PatientHomeScreen({super.key});

  @override
  State<PatientHomeScreen> createState() => _PatientHomeScreenState();
}

class _PatientHomeScreenState extends State<PatientHomeScreen> {
  int _index = 0;
  StreamSubscription<MedicationAlarmEvent>? _alarmSubscription;
  StreamSubscription<List<Medicine>>? _medicineSubscription;
  Future<void> _alarmEventQueue = Future<void>.value();
  Future<void> _alarmDialogQueue = Future<void>.value();
  String? _activeAlarmMedicineId;
  bool _alarmDialogOpen = false;
  final Set<String> _handledAlarmEvents = {};
  static const _titles = ['Beranda', 'Riwayat Obat', 'Profil'];

  @override
  void initState() {
    super.initState();
    _alarmSubscription = ReminderService.instance.alarmEvents.listen(
      _enqueueAlarmEvent,
    );
    final userId = context.read<AuthService>().user!.uid;
    _medicineSubscription = context
        .read<MedicineRepository>()
        .medicinesForPatient(userId)
        .listen(_closeCompletedAlarm);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final event in ReminderService.instance.takePendingEvents()) {
        _enqueueAlarmEvent(event);
      }
    });
  }

  void _enqueueAlarmEvent(MedicationAlarmEvent event) {
    _alarmEventQueue = _alarmEventQueue
        .then((_) => _handleAlarmEvent(event))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Gagal memproses antrean alarm: $error\n$stackTrace');
        });
  }

  Future<void> _handleAlarmEvent(MedicationAlarmEvent event) async {
    if (!mounted || event.medicineId.isEmpty) return;
    final eventKey =
        '${event.medicineId}:${event.action}:'
        '${event.occurredAt?.millisecondsSinceEpoch ?? 0}';
    if (!_handledAlarmEvents.add(eventKey)) return;
    if (_handledAlarmEvents.length > 32) {
      _handledAlarmEvents.remove(_handledAlarmEvents.first);
    }
    final userId = context.read<AuthService>().user?.uid;
    if (userId == null) {
      _handledAlarmEvents.remove(eventKey);
      return;
    }
    if (event.patientId.isNotEmpty && event.patientId != userId) {
      await ReminderService.instance.stopAlarmForMedicine(event.medicineId);
      await ReminderService.instance.acknowledgeAlarmEvent(event);
      return;
    }
    final repository = context.read<MedicineRepository>();
    Medicine? medicine;
    try {
      medicine = await repository.medicineById(event.medicineId);
    } catch (error) {
      _handledAlarmEvents.remove(eventKey);
      debugPrint('Gagal memeriksa jadwal alarm: $error');
      _retryAlarmEvent(event, eventKey);
      return;
    }
    if (!mounted) return;
    if (medicine == null) {
      await ReminderService.instance.stopAlarmForMedicine(event.medicineId);
      await ReminderService.instance.acknowledgeAlarmEvent(event);
      return;
    }
    final currentMedicine = medicine;
    final normalizedAction = event.action.toLowerCase();
    final isRecoverableLateTaken =
        normalizedAction.contains('taken') &&
        currentMedicine.canRecoverAutomaticMissedAt(DateTime.now());
    if (!currentMedicine.isPending && !isRecoverableLateTaken) {
      await ReminderService.instance.stopAlarmForMedicine(event.medicineId);
      await ReminderService.instance.acknowledgeAlarmEvent(event);
      return;
    }
    if (!isRecoverableLateTaken &&
        !_matchesCurrentSchedule(event, currentMedicine)) {
      await ReminderService.instance.stopAlarmForMedicine(currentMedicine.id);
      await ReminderService.instance.scheduleMedicineWithoutSync(
        currentMedicine,
      );
      await ReminderService.instance.acknowledgeAlarmEvent(event);
      return;
    }

    if (normalizedAction.contains('taken')) {
      _closeAlarmDialog();
      unawaited(
        _respondToNativeEvent(
          repository,
          currentMedicine,
          event,
          eventKey,
          'taken',
        ),
      );
      return;
    }
    if (normalizedAction.contains('snooze')) {
      _closeAlarmDialog();
      unawaited(
        _respondToNativeEvent(
          repository,
          currentMedicine,
          event,
          eventKey,
          'snooze',
          snoozedUntil: event.snoozedUntil,
        ),
      );
      return;
    }
    if (normalizedAction.contains('dismiss')) {
      _closeAlarmDialog();
      unawaited(
        _respondToNativeEvent(
          repository,
          currentMedicine,
          event,
          eventKey,
          'dismiss',
        ),
      );
      return;
    }
    unawaited(
      _persistTriggeredEvent(repository, currentMedicine, event, eventKey),
    );
    _enqueueAlarmDialog(repository, currentMedicine, event);
  }

  void _enqueueAlarmDialog(
    MedicineRepository repository,
    Medicine medicine,
    MedicationAlarmEvent event,
  ) {
    _alarmDialogQueue = _alarmDialogQueue
        .then((_) => _showAlarmDialog(repository, medicine, event))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Gagal membuka dialog alarm: $error\n$stackTrace');
        });
  }

  Future<void> _showAlarmDialog(
    MedicineRepository repository,
    Medicine originalMedicine,
    MedicationAlarmEvent event,
  ) async {
    if (!mounted) return;
    Medicine medicine = originalMedicine;
    try {
      final latest = await repository.medicineById(originalMedicine.id);
      if (latest == null || !latest.isPending || !mounted) return;
      medicine = latest;
    } catch (_) {
      // The already-loaded pending schedule is enough to display the alarm.
    }
    if (!mounted) return;
    if (!_matchesCurrentSchedule(event, medicine)) return;
    _activeAlarmMedicineId = medicine.id;
    _alarmDialogOpen = true;
    final action = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, _, _) => _MedicationAlarmDialog(
        medicine: medicine,
        scheduledAt: event.scheduledAt ?? medicine.scheduledAt,
      ),
      transitionBuilder: (context, animation, _, child) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: .94, end: 1).animate(animation),
          child: child,
        ),
      ),
    );
    _alarmDialogOpen = false;
    _activeAlarmMedicineId = null;
    if (action != null && mounted) {
      // Firestore may remain pending while the device is offline. Do not let
      // that response block a second medicine's already-ringing dialog.
      unawaited(_respondToAlarm(repository, medicine, action));
    }
  }

  bool _matchesCurrentSchedule(MedicationAlarmEvent event, Medicine medicine) {
    final eventTime = event.scheduledAt;
    final expectedTime = medicine.snoozedUntil ?? medicine.scheduledAt;
    if (eventTime == null || expectedTime == null) return true;
    return eventTime.difference(expectedTime).abs() <=
        const Duration(seconds: 2);
  }

  Future<bool> _respondToAlarm(
    MedicineRepository repository,
    Medicine medicine,
    String action, {
    bool nativeHandled = false,
    DateTime? snoozedUntil,
  }) async {
    try {
      if (action == 'snooze') {
        const duration = Duration(minutes: 5);
        if (!nativeHandled) {
          await ReminderService.instance.snooze(medicine, duration: duration);
        }
        await repository.snoozeMedicine(
          medicine,
          until: snoozedUntil ?? DateTime.now().add(duration),
        );
      } else {
        if (!nativeHandled) {
          await ReminderService.instance.stopAlarmForMedicine(medicine.id);
        }
        if (action == 'taken') {
          await repository.markAsTaken(medicine);
        } else {
          await repository.dismissMedicineAlarm(medicine);
        }
      }
      if (mounted) {
        final message = switch (action) {
          'taken' => 'Obat berhasil dicatat sebagai diminum.',
          'snooze' => 'Alarm ditunda selama 5 menit.',
          _ => 'Alarm dihentikan. Jadwal tetap menunggu konfirmasi.',
        };
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      return true;
    } catch (error, stackTrace) {
      debugPrint('Gagal menyimpan respons alarm: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Respons belum tersimpan. Silakan coba kembali.'),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _persistTriggeredEvent(
    MedicineRepository repository,
    Medicine medicine,
    MedicationAlarmEvent event,
    String eventKey,
  ) async {
    try {
      await repository.recordReminderTriggered(medicine);
      await ReminderService.instance.acknowledgeAlarmEvent(event);
    } catch (error) {
      _handledAlarmEvents.remove(eventKey);
      debugPrint('Gagal mencatat alarm obat: $error');
      _retryAlarmEvent(event, eventKey);
    }
  }

  Future<void> _respondToNativeEvent(
    MedicineRepository repository,
    Medicine medicine,
    MedicationAlarmEvent event,
    String eventKey,
    String action, {
    DateTime? snoozedUntil,
  }) async {
    final saved = await _respondToAlarm(
      repository,
      medicine,
      action,
      nativeHandled: true,
      snoozedUntil: snoozedUntil,
    );
    await _finishNativeResponse(event, eventKey, saved);
  }

  Future<void> _finishNativeResponse(
    MedicationAlarmEvent event,
    String eventKey,
    bool saved,
  ) async {
    if (saved) {
      await ReminderService.instance.acknowledgeAlarmEvent(event);
    } else {
      _handledAlarmEvents.remove(eventKey);
      _retryAlarmEvent(event, eventKey);
    }
  }

  void _retryAlarmEvent(MedicationAlarmEvent event, String eventKey) {
    unawaited(
      Future<void>.delayed(const Duration(seconds: 10), () {
        if (mounted && !_handledAlarmEvents.contains(eventKey)) {
          _enqueueAlarmEvent(event);
        }
      }),
    );
  }

  void _closeCompletedAlarm(List<Medicine> medicines) {
    final activeId = _activeAlarmMedicineId;
    if (activeId == null) return;
    final stillPending = medicines.any(
      (medicine) => medicine.id == activeId && medicine.isPending,
    );
    if (stillPending) return;
    unawaited(ReminderService.instance.stopAlarmForMedicine(activeId));
    _closeAlarmDialog();
  }

  void _closeAlarmDialog() {
    if (!_alarmDialogOpen || !mounted) return;
    _alarmDialogOpen = false;
    _activeAlarmMedicineId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    });
  }

  @override
  void dispose() {
    _alarmSubscription?.cancel();
    _medicineSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      const _PatientHomePage(),
      const _MedicationHistoryPage(),
      const AccountProfilePage(isPatient: true),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        automaticallyImplyLeading: false,
      ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Beranda',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_rounded),
            selectedIcon: Icon(Icons.history_toggle_off_rounded),
            label: 'Riwayat',
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

class _PatientHomePage extends StatefulWidget {
  const _PatientHomePage();

  @override
  State<_PatientHomePage> createState() => _PatientHomePageState();
}

class _PatientHomePageState extends State<_PatientHomePage> {
  late final Timer _clock;
  late final MedicineRepository _repository;
  late final String _userId;
  late final Stream<UserProfile> _profileStream;
  late final Stream<List<Medicine>> _medicineStream;
  DateTime _now = DateTime.now();
  String? _lastReminderSignature;
  bool? _notificationPermissionGranted;
  bool _alarmAccessRequested = false;

  @override
  void initState() {
    super.initState();
    _repository = context.read<MedicineRepository>();
    _userId = context.read<AuthService>().user!.uid;
    _profileStream = _repository.profile(_userId);
    _medicineStream = _repository.medicinesForPatient(_userId);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserProfile>(
      stream: _profileStream,
      builder: (context, profileSnapshot) {
        if (profileSnapshot.hasError) {
          return AsyncErrorView(error: profileSnapshot.error);
        }
        if (!profileSnapshot.hasData) {
          return const AppLoadingView(message: 'Memuat profil pasien…');
        }
        final profile = profileSnapshot.data!;
        return StreamBuilder<List<Medicine>>(
          stream: _medicineStream,
          builder: (context, medicineSnapshot) {
            if (medicineSnapshot.hasError) {
              return AsyncErrorView(error: medicineSnapshot.error);
            }
            if (!medicineSnapshot.hasData) {
              return const AppLoadingView(message: 'Memuat jadwal obat…');
            }
            final allMedicines = medicineSnapshot.data!;
            final scheduledForAdherence = allMedicines
                .where(
                  (medicine) =>
                      medicine.scheduledAt != null &&
                      !medicine.scheduledAt!.isAfter(_now),
                )
                .toList(growable: false);
            final confirmedDoses = scheduledForAdherence
                .where((medicine) => medicine.isTaken)
                .length;
            final today =
                allMedicines
                    .where(
                      (medicine) =>
                          _sameDay(medicine.scheduledAt, _now) ||
                          medicine.canRecoverAutomaticMissedAt(_now),
                    )
                    .toList()
                  ..sort(
                    (a, b) => (a.scheduledAt ?? DateTime(2100)).compareTo(
                      b.scheduledAt ?? DateTime(2100),
                    ),
                  );
            final scheduledToday = allMedicines
                .where((medicine) => _sameDay(medicine.scheduledAt, _now))
                .toList(growable: false);
            _reconcileReminders(
              enabled: profile.notificationsEnabled,
              medicines: allMedicines,
            );
            final pendingUpcoming =
                allMedicines
                    .where(
                      (medicine) =>
                          medicine.isPending &&
                          (_alarmTime(medicine, _now)?.isAfter(_now) ?? false),
                    )
                    .toList()
                  ..sort(
                    (a, b) =>
                        _alarmTime(a, _now)!.compareTo(_alarmTime(b, _now)!),
                  );
            final upcoming = pendingUpcoming.firstOrNull;
            final upcomingAt = upcoming == null
                ? null
                : _alarmTime(upcoming, _now);
            final futureSchedules = pendingUpcoming
                .where((medicine) => !_sameDay(medicine.scheduledAt, _now))
                .take(5)
                .toList(growable: false);
            final treatmentProgress =
                profile.treatmentStartedAt == null ||
                    profile.treatmentGroup != TreatmentPlan.group1
                ? 0.0
                : TreatmentPlan.progress(
                    group: profile.treatmentGroup,
                    treatmentStartedAt: profile.treatmentStartedAt!,
                    now: _now,
                  );
            final todayStatus = _todayMedicationStatus(scheduledToday, _now);
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                _PatientWelcomeHeader(
                  profile: profile,
                  todayStatus: todayStatus,
                  now: _now,
                ),
                const SizedBox(height: 16),
                _NextDoseBanner(
                  medicine: upcoming,
                  scheduledAt: upcomingAt,
                  now: _now,
                ),
                const SizedBox(height: 18),
                _PatientTreatmentSummary(
                  profile: profile,
                  progress: treatmentProgress,
                  hasScheduleToday: scheduledToday.isNotEmpty,
                  todayStatus: todayStatus,
                ),
                const SizedBox(height: 22),
                _SectionHeader(
                  icon: Icons.today_rounded,
                  title: 'Jadwal hari ini',
                  subtitle: MaterialLocalizations.of(
                    context,
                  ).formatFullDate(_now),
                  count: today.length,
                ),
                const SizedBox(height: 10),
                const _MedicationTimingNotice(),
                const SizedBox(height: 10),
                if (today.isEmpty)
                  const _EmptyCard(
                    icon: Icons.event_available_outlined,
                    title: 'Tidak ada jadwal hari ini',
                    message:
                        'Hari ini bukan hari minum obat. Jika seharusnya ada '
                        'jadwal, minta pengawas memeriksa waktu obat.',
                  )
                else
                  ...today.map(
                    (medicine) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _MedicationScheduleCard(
                        medicine: medicine,
                        repository: _repository,
                        now: _now,
                      ),
                    ),
                  ),
                const SizedBox(height: 22),
                _SectionHeader(
                  icon: Icons.date_range_rounded,
                  title: 'Jadwal akan datang',
                  subtitle: 'Lima jadwal pengobatan berikutnya',
                  count: futureSchedules.length,
                ),
                const SizedBox(height: 10),
                if (futureSchedules.isEmpty)
                  _EmptyCard(
                    icon: Icons.event_busy_outlined,
                    title: 'Jadwal berikutnya belum tersedia',
                    message: profile.treatmentGroup == TreatmentPlan.group1
                        ? 'Belum ada jadwal berikutnya. Pastikan pengawas sudah mengatur jam minum obat.'
                        : 'Golongan ini belum memiliki aturan jadwal otomatis.',
                  )
                else
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (
                          var index = 0;
                          index < futureSchedules.length;
                          index++
                        ) ...[
                          _UpcomingScheduleTile(
                            medicine: futureSchedules[index],
                            treatmentGroup: profile.treatmentGroup,
                            treatmentStartedAt: profile.treatmentStartedAt,
                            isFirst: index == 0,
                          ),
                          if (index < futureSchedules.length - 1)
                            const Divider(height: 1, indent: 78),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 18),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: AdherenceIndicator(
                      confirmedDoses: confirmedDoses,
                      totalScheduledDoses: scheduledForAdherence.length,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TreatmentMonitoringPanel(
                  profile: profile,
                  confirmedDoses: confirmedDoses,
                  totalScheduledDoses: scheduledForAdherence.length,
                  isCaregiver: false,
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _reconcileReminders({
    required bool enabled,
    required List<Medicine> medicines,
  }) {
    final signature = [
      enabled,
      for (final medicine in medicines)
        '${medicine.id}:${medicine.status}:${medicine.scheduleRevision}:'
            '${medicine.scheduledAt?.millisecondsSinceEpoch}:'
            '${medicine.snoozedUntil?.millisecondsSinceEpoch}',
    ].join('|');
    if (_lastReminderSignature == signature) return;
    _lastReminderSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!enabled) {
        await ReminderService.instance.scheduleMedicines(const []);
        return;
      }
      _notificationPermissionGranted ??= await ReminderService.instance
          .requestPermission();
      if (_notificationPermissionGranted == true) {
        if (!_alarmAccessRequested) {
          _alarmAccessRequested = true;
          await ReminderService.instance.requestAlarmAccess();
        }
        await ReminderService.instance.scheduleMedicines(medicines);
      }
    });
  }
}

class _PatientWelcomeHeader extends StatelessWidget {
  const _PatientWelcomeHeader({
    required this.profile,
    required this.todayStatus,
    required this.now,
  });

  final UserProfile profile;
  final String todayStatus;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final isOnTime = todayStatus == 'Tepat waktu';
    final statusColor = isOnTime
        ? const Color(0xFFBFF1D8)
        : todayStatus == 'Terlambat'
        ? const Color(0xFFFFD79A)
        : todayStatus == 'Terlewat'
        ? const Color(0xFFFFC9C6)
        : todayStatus == 'Belum diminum'
        ? const Color(0xFFFFE6A7)
        : Colors.white.withValues(alpha: .82);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF087E69), Color(0xFF13A684)],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(
            color: Color(0x29036B59),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .24),
              shape: BoxShape.circle,
            ),
            child: ProfileAvatar(
              name: profile.fullName,
              photoUrl: profile.photoUrl,
              radius: 30,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Halo, ${_firstName(profile.fullName)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  MaterialLocalizations.of(context).formatFullDate(now),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .82),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Hari ini: $todayStatus',
                    style: const TextStyle(
                      color: Color(0xFF17493F),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NextDoseBanner extends StatelessWidget {
  const _NextDoseBanner({
    required this.medicine,
    required this.scheduledAt,
    required this.now,
  });

  final Medicine? medicine;
  final DateTime? scheduledAt;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final date = scheduledAt;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F7F2),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFBFE7DA)),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: medicine == null
                  ? const Color(0xFFD6E7E2)
                  : const Color(0xFF07866F),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Icon(
              medicine == null
                  ? Icons.event_available_rounded
                  : Icons.alarm_rounded,
              color: medicine == null ? const Color(0xFF52746C) : Colors.white,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'DOSIS BERIKUTNYA',
                  style: TextStyle(
                    color: Color(0xFF50736B),
                    fontSize: 11,
                    letterSpacing: .8,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  medicine == null || date == null
                      ? 'Belum ada jadwal aktif'
                      : '${_time(context, date)} · ${medicine!.name}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (date != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    '${_sameDay(date, now) ? 'Hari ini' : _dateText(context, date)} · ${_countdown(date, now)}',
                    style: const TextStyle(
                      color: Color(0xFF476A62),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.count,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final int count;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: const Color(0xFFDFF3EC),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Icon(icon, color: const Color(0xFF087A66), size: 21),
      ),
      const SizedBox(width: 11),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFE7F5F0),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '$count',
          style: const TextStyle(
            color: Color(0xFF087A66),
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    ],
  );
}

class _UpcomingScheduleTile extends StatelessWidget {
  const _UpcomingScheduleTile({
    required this.medicine,
    required this.treatmentGroup,
    required this.treatmentStartedAt,
    required this.isFirst,
  });

  final Medicine medicine;
  final String treatmentGroup;
  final DateTime? treatmentStartedAt;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final scheduledAt = medicine.scheduledAt;
    final phase = _phaseLabel(
      group: treatmentGroup,
      treatmentStartedAt: treatmentStartedAt,
      scheduledAt: scheduledAt,
    );
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      leading: Container(
        width: 50,
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: isFirst ? const Color(0xFF07866F) : const Color(0xFFE8F5F1),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              scheduledAt?.day.toString() ?? '-',
              style: TextStyle(
                color: isFirst ? Colors.white : const Color(0xFF126F5E),
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              scheduledAt == null
                  ? '-'
                  : _shortMonth(context, scheduledAt).toUpperCase(),
              style: TextStyle(
                color: isFirst
                    ? Colors.white.withValues(alpha: .85)
                    : const Color(0xFF4C766D),
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              scheduledAt == null
                  ? 'Tanggal belum tersedia'
                  : MaterialLocalizations.of(
                      context,
                    ).formatFullDate(scheduledAt),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          if (isFirst)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Chip(
                visualDensity: VisualDensity.compact,
                label: Text('Terdekat'),
              ),
            ),
        ],
      ),
      subtitle: Text('${_time(context, scheduledAt)} · $phase'),
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }
}

class _PatientTreatmentSummary extends StatelessWidget {
  const _PatientTreatmentSummary({
    required this.profile,
    required this.progress,
    required this.hasScheduleToday,
    required this.todayStatus,
  });

  final UserProfile profile;
  final double progress;
  final bool hasScheduleToday;
  final String todayStatus;

  @override
  Widget build(BuildContext context) {
    final age = profile.ageAt(DateTime.now());
    final medicationTime = profile.hasMedicationTime
        ? formatMedicationTime(
            profile.medicationHour!,
            profile.medicationMinute!,
          )
        : 'Belum diatur pengawas';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ringkasan terapi',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${age == null ? 'Umur belum diisi' : '$age tahun'} · '
                        '${profile.ageCategoryAt(DateTime.now())} · '
                        '${profile.genderLabel}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Chip(
                  label: Text(TreatmentPlan.labelFor(profile.treatmentGroup)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: _CompactTreatmentMetric(
                    icon: Icons.schedule_rounded,
                    label: 'Waktu obat',
                    value: medicationTime,
                  ),
                ),
                const SizedBox(height: 42, child: VerticalDivider(width: 16)),
                Expanded(
                  child: _CompactTreatmentMetric(
                    icon: todayStatus == 'Tepat waktu'
                        ? Icons.check_circle_outline_rounded
                        : Icons.today_outlined,
                    label: hasScheduleToday ? 'Status hari ini' : 'Hari ini',
                    value: hasScheduleToday ? todayStatus : 'Tanpa jadwal',
                  ),
                ),
                const SizedBox(height: 42, child: VerticalDivider(width: 16)),
                Expanded(
                  child: _CompactTreatmentMetric(
                    icon: Icons.trending_up_rounded,
                    label: 'Progres',
                    value: '${(progress * 100).round()}%',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: LinearProgressIndicator(
                value: progress.clamp(0, 1),
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactTreatmentMetric extends StatelessWidget {
  const _CompactTreatmentMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18, color: const Color(0xFF087A66)),
      const SizedBox(height: 4),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
      ),
    ],
  );
}

class _MedicationTimingNotice extends StatelessWidget {
  const _MedicationTimingNotice();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .48),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.primary.withValues(alpha: .2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.timer_outlined, color: colors.primary, size: 21),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              'Tepat waktu sampai ${medicationLateGracePeriod.inMinutes} menit setelah jadwal. '
              'Jika belum dikonfirmasi pada menit ke-${medicationLateGracePeriod.inMinutes}, '
              'pengawas menerima notifikasi; setelah batas itu status menjadi terlambat. '
              'Jika belum dikonfirmasi selama ${medicationMissedAfter.inHours} jam, '
              'status menjadi terlewat.',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _MedicationScheduleCard extends StatefulWidget {
  const _MedicationScheduleCard({
    required this.medicine,
    required this.repository,
    required this.now,
  });
  final Medicine medicine;
  final MedicineRepository repository;
  final DateTime now;

  @override
  State<_MedicationScheduleCard> createState() =>
      _MedicationScheduleCardState();
}

class _MedicationScheduleCardState extends State<_MedicationScheduleCard> {
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final medicine = widget.medicine;
    final status = _effectiveStatus(medicine, widget.now);
    final canSkip =
        medicine.scheduledAt == null ||
        !medicine.scheduledAt!.isAfter(widget.now);
    final canRecoverLate = medicine.canRecoverAutomaticMissedAt(widget.now);
    final color = switch (status) {
      'Tepat waktu' => const Color(0xFF268B67),
      'Terlambat' || 'Waktunya minum' => const Color(0xFFE08A20),
      'Terlewat' => const Color(0xFFD24F4A),
      _ => Theme.of(context).colorScheme.primary,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.medication_rounded, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        medicine.displayName,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              letterSpacing: .8,
                            ),
                      ),
                      Text(
                        medicine.dosage?.isNotEmpty == true
                            ? medicine.dosage!
                            : 'Dosis belum tercatat',
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.schedule_rounded, size: 17),
                          const SizedBox(width: 5),
                          Text(_time(context, medicine.scheduledAt)),
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(color: color, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            if (medicine.isPending || canRecoverLate) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  if (medicine.isPending) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSaving || !canSkip
                            ? null
                            : () => _saveStatus(taken: false),
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('Lewati dosis'),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _isSaving
                          ? null
                          : () => _saveStatus(taken: true),
                      icon: const Icon(Icons.check_circle_outline_rounded),
                      label: Text(
                        _isSaving
                            ? 'Menyimpan…'
                            : canRecoverLate
                            ? 'Diminum terlambat'
                            : 'Minum obat',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _saveStatus({required bool taken}) async {
    final scheduledAt = widget.medicine.scheduledAt;
    final isLateResponse =
        taken &&
        scheduledAt != null &&
        isMedicationLate(scheduledAt: scheduledAt, respondedAt: DateTime.now());
    setState(() => _isSaving = true);
    await ReminderService.instance.stopAlarmForMedicine(widget.medicine.id);
    try {
      if (taken) {
        await widget.repository.markAsTaken(widget.medicine);
      } else {
        await widget.repository.markAsMissed(widget.medicine);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              taken
                  ? widget.medicine.isAutomaticallyMissed || isLateResponse
                        ? 'Dosis diperbarui sebagai diminum terlambat.'
                        : 'Dosis dicatat tepat waktu.'
                  : 'Dosis dicatat sebagai terlewat.',
            ),
          ),
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Gagal menyimpan status dosis: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Catatan belum tersimpan. Silakan coba kembali.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

class _MedicationHistoryPage extends StatefulWidget {
  const _MedicationHistoryPage();
  @override
  State<_MedicationHistoryPage> createState() => _MedicationHistoryPageState();
}

class _MedicationHistoryPageState extends State<_MedicationHistoryPage> {
  DateTime? _date;
  final Set<String> _savingRecoveryIds = {};

  @override
  Widget build(BuildContext context) {
    final userId = context.read<AuthService>().user!.uid;
    final repository = context.read<MedicineRepository>();
    return StreamBuilder<List<Medicine>>(
      stream: repository.medicinesForPatient(userId),
      builder: (context, snapshot) {
        if (snapshot.hasError) return AsyncErrorView(error: snapshot.error);
        if (!snapshot.hasData) {
          return const AppLoadingView(message: 'Memuat riwayat obat…');
        }
        final all = snapshot.data!;
        final completed = all
            .where((m) => m.isTaken || m.status == 'missed')
            .toList();
        final shown = _date == null
            ? completed
            : completed.where((m) => _sameDay(m.scheduledAt, _date)).toList();
        final taken = completed.where((m) => m.isTaken).length;
        final adherence = completed.isEmpty
            ? 0
            : (taken * 100 / completed.length).round();
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: CircularProgressIndicator(
                        value: adherence / 100,
                        strokeWidth: 8,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$adherence% kepatuhan',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const Text('Berdasarkan dosis yang telah tercatat'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                  initialDate: _date ?? DateTime.now(),
                );
                if (picked != null) setState(() => _date = picked);
              },
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(
                _date == null
                    ? 'Filter berdasarkan tanggal'
                    : MaterialLocalizations.of(
                        context,
                      ).formatMediumDate(_date!),
              ),
            ),
            if (_date != null)
              TextButton(
                onPressed: () => setState(() => _date = null),
                child: const Text('Hapus filter tanggal'),
              ),
            const SizedBox(height: 10),
            if (shown.isEmpty)
              _EmptyCard(
                icon: Icons.history_rounded,
                title: _date == null
                    ? 'Riwayat obat masih kosong'
                    : 'Tidak ada catatan pada tanggal ini',
                message: _date == null
                    ? 'Riwayat akan muncul setelah Anda mengonfirmasi dosis '
                          'sebagai sudah diminum atau tidak diminum.'
                    : 'Pilih tanggal lain atau hapus filter untuk melihat '
                          'seluruh riwayat obat.',
              )
            else
              ...shown.map((m) {
                final canRecover = m.canRecoverAutomaticMissedAt(
                  DateTime.now(),
                );
                final isSaving = _savingRecoveryIds.contains(m.id);
                return Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.all(14),
                        leading: CircleAvatar(
                          child: Icon(
                            m.isTaken
                                ? Icons.check_rounded
                                : Icons.close_rounded,
                          ),
                        ),
                        title: Text(
                          m.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          m.status == 'missed'
                              ? '${_dateText(context, m.scheduledAt)}\nJadwal ${_time(context, m.scheduledAt)} • Tidak diminum'
                              : '${_dateText(context, m.scheduledAt)}\nJadwal ${_time(context, m.scheduledAt)} • Diminum ${_time(context, m.takenAt)}',
                        ),
                        isThreeLine: true,
                        trailing: Text(
                          m.displayStatus,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      if (canRecover)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                          child: FilledButton.icon(
                            onPressed: isSaving
                                ? null
                                : () => _recoverAutomaticMissed(repository, m),
                            icon: const Icon(
                              Icons.check_circle_outline_rounded,
                            ),
                            label: Text(
                              isSaving
                                  ? 'Menyimpan…'
                                  : 'Catat diminum terlambat',
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  Future<void> _recoverAutomaticMissed(
    MedicineRepository repository,
    Medicine medicine,
  ) async {
    setState(() => _savingRecoveryIds.add(medicine.id));
    await ReminderService.instance.stopAlarmForMedicine(medicine.id);
    try {
      await repository.markAsTaken(medicine);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Dosis diperbarui sebagai diminum terlambat.'),
          ),
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Gagal memulihkan dosis terlewat: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Catatan belum tersimpan. Silakan coba kembali.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingRecoveryIds.remove(medicine.id));
    }
  }
}

class _MedicationAlarmDialog extends StatelessWidget {
  const _MedicationAlarmDialog({
    required this.medicine,
    required this.scheduledAt,
  });

  final Medicine medicine;
  final DateTime? scheduledAt;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return PopScope(
      canPop: false,
      child: Material(
        color: const Color(0xFF063E35),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Column(
              children: [
                const Text(
                  'PENGINGAT OBAT',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const Spacer(),
                Container(
                  width: 116,
                  height: 116,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: .12),
                    border: Border.all(color: Colors.white30, width: 2),
                  ),
                  child: const Icon(
                    Icons.alarm_rounded,
                    color: Colors.white,
                    size: 62,
                  ),
                ),
                const SizedBox(height: 30),
                Text(
                  _time(context, scheduledAt),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 52,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  medicine.displayName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  medicine.dosage?.isNotEmpty == true
                      ? medicine.dosage!
                      : 'Minum sesuai petunjuk',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 17),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: primary,
                      minimumSize: const Size.fromHeight(58),
                    ),
                    onPressed: () => Navigator.pop(context, 'taken'),
                    icon: const Icon(Icons.check_circle_rounded),
                    label: const Text(
                      'Sudah diminum',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                    ),
                    onPressed: () => Navigator.pop(context, 'snooze'),
                    icon: const Icon(Icons.snooze_rounded),
                    label: const Text('Tunda 5 menit'),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'dismiss'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  child: const Text('Matikan alarm'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.title,
    required this.message,
    this.icon = Icons.inbox_outlined,
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
String _time(BuildContext _, DateTime? date) => date == null
    ? 'Belum tercatat'
    : formatMedicationTime(date.hour, date.minute);
String _dateText(BuildContext context, DateTime? date) => date == null
    ? 'Tanggal belum tercatat'
    : MaterialLocalizations.of(context).formatMediumDate(date);
String _shortMonth(BuildContext _, DateTime date) => const [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'Mei',
  'Jun',
  'Jul',
  'Agu',
  'Sep',
  'Okt',
  'Nov',
  'Des',
][date.month - 1];
String _phaseLabel({
  required String group,
  required DateTime? treatmentStartedAt,
  required DateTime? scheduledAt,
}) {
  if (group != TreatmentPlan.group1) return 'Aturan belum tersedia';
  if (treatmentStartedAt == null || scheduledAt == null) {
    return 'Jadwal terapi';
  }
  final intensiveEnd = TreatmentPlan.addMonths(
    TreatmentPlan.dateOnly(treatmentStartedAt),
    2,
  );
  return scheduledAt.isBefore(intensiveEnd)
      ? 'Fase intensif · setiap hari'
      : 'Fase lanjutan · Sen–Rab–Jum';
}

String _firstName(String name) =>
    name.trim().isEmpty ? 'Sobat' : name.trim().split(RegExp(r'\s+')).first;
String _todayMedicationStatus(List<Medicine> medicines, DateTime now) {
  if (medicines.isEmpty) return 'Tidak ada jadwal';
  if (medicines.any((medicine) => medicine.status == 'missed')) {
    return 'Terlewat';
  }
  if (medicines.any(
    (medicine) =>
        medicine.isPending &&
        medicine.scheduledAt != null &&
        hasMedicationMissedDeadlinePassed(
          scheduledAt: medicine.scheduledAt!,
          now: now,
        ),
  )) {
    return 'Terlewat';
  }
  if (medicines.any((medicine) => medicine.isLateConfirmation)) {
    return 'Terlambat';
  }
  if (medicines.any((medicine) => medicine.isTakenOnTime)) {
    return 'Tepat waktu';
  }
  if (medicines.any(
    (medicine) =>
        medicine.isPending &&
        medicine.scheduledAt != null &&
        isMedicationLate(scheduledAt: medicine.scheduledAt!, respondedAt: now),
  )) {
    return 'Terlambat';
  }
  return 'Belum diminum';
}

String _effectiveStatus(Medicine medicine, DateTime now) {
  if (medicine.status == 'pending') {
    if (medicine.snoozedUntil?.isAfter(now) ?? false) return 'Ditunda';
    final scheduledAt = medicine.scheduledAt;
    if (scheduledAt != null && !scheduledAt.isAfter(now)) {
      if (hasMedicationMissedDeadlinePassed(
        scheduledAt: scheduledAt,
        now: now,
      )) {
        return 'Terlewat';
      }
      if (isMedicationLate(scheduledAt: scheduledAt, respondedAt: now)) {
        return 'Terlambat';
      }
      return 'Waktunya minum';
    }
  }
  return medicine.displayStatus;
}

DateTime? _alarmTime(Medicine medicine, DateTime now) =>
    medicine.snoozedUntil?.isAfter(now) == true
    ? medicine.snoozedUntil
    : medicine.scheduledAt;

String _countdown(DateTime date, DateTime now) {
  final remaining = medicationCountdown(date, now);
  if (remaining == Duration.zero) return 'Waktunya sekarang';
  final days = remaining.inDays;
  if (days > 0) {
    final remainingHours = remaining.inHours.remainder(24);
    return remainingHours == 0
        ? 'Dalam $days hari'
        : 'Dalam $days hari $remainingHours jam';
  }
  final hours = remaining.inHours;
  final minutes = remaining.inMinutes.remainder(60);
  final seconds = remaining.inSeconds.remainder(60);
  final parts = <String>[];
  if (hours > 0) parts.add('${hours}j');
  parts.add('${minutes.toString().padLeft(2, '0')}m');
  parts.add('${seconds.toString().padLeft(2, '0')}d');
  return 'Dalam ${parts.join(' ')}';
}
