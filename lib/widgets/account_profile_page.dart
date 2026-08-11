import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/user_profile.dart';
import '../services/auth_service.dart';
import '../services/medicine_repository.dart';
import '../services/push_notification_service.dart';
import '../services/reminder_service.dart';
import 'async_error_view.dart';
import 'app_state_view.dart';
import 'profile_avatar.dart';

class AccountProfilePage extends StatelessWidget {
  const AccountProfilePage({super.key, required this.isPatient});

  final bool isPatient;

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthService>();
    final repository = context.read<MedicineRepository>();
    return StreamBuilder<UserProfile>(
      stream: repository.profile(auth.user!.uid),
      builder: (context, snapshot) {
        if (snapshot.hasError) return AsyncErrorView(error: snapshot.error);
        if (!snapshot.hasData) {
          return const AppLoadingView(message: 'Memuat profil akun…');
        }
        final profile = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            const SizedBox(height: 12),
            Center(
              child: ProfileAvatar(
                name: profile.fullName,
                photoUrl: profile.photoUrl,
                radius: 48,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              profile.fullName,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            Text(
              isPatient ? 'Pasien' : (profile.relationship ?? 'Pendamping'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 24),
            Card(
              child: Column(
                children: [
                  _InfoTile(
                    icon: Icons.email_outlined,
                    label: 'Email',
                    value: profile.email,
                  ),
                  _InfoTile(
                    icon: Icons.phone_outlined,
                    label: 'Telepon',
                    value: profile.phoneNumber,
                  ),
                  if (isPatient)
                    _InfoTile(
                      icon: Icons.badge_outlined,
                      label: 'Kode pasien',
                      value: profile.patientCode ?? profile.id,
                      trailing: IconButton(
                        tooltip: 'Salin kode',
                        onPressed: () async {
                          final code = profile.patientCode ?? profile.id;
                          await Clipboard.setData(ClipboardData(text: code));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Kode pasien disalin.'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy_rounded),
                      ),
                    ),
                  if (isPatient)
                    _InfoTile(
                      icon: Icons.cake_outlined,
                      label: 'Usia',
                      value: profile.ageAt(DateTime.now()) == null
                          ? 'Belum diisi'
                          : '${profile.ageAt(DateTime.now())} tahun · ${profile.ageCategoryAt(DateTime.now())}',
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Edit profil'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _editProfile(context, profile, repository),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_outlined),
                    title: const Text('Notifikasi obat'),
                    subtitle: const Text(
                      'Pengingat berdasarkan jadwal yang tersedia',
                    ),
                    value: profile.notificationsEnabled,
                    onChanged: (value) async {
                      if (value) {
                        final granted = await ReminderService.instance
                            .requestPermission();
                        if (!granted && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Izin notifikasi tidak diberikan.'),
                            ),
                          );
                          return;
                        }
                        if (isPatient) {
                          await ReminderService.instance.requestAlarmAccess();
                        }
                      }
                      await repository.updateNotificationSetting(
                        profile.id,
                        value,
                      );
                      PushNotificationService.instance.reconfigureForUser(
                        profile.id,
                      );
                      if (value && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Notifikasi diaktifkan. Perangkat mungkin akan meminta izin.',
                            ),
                          ),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.lock_outline_rounded),
                    title: const Text('Ubah kata sandi'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _changePassword(context, profile.email),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Keluar'),
              onPressed: () => context.read<AuthService>().signOut(),
            ),
          ],
        );
      },
    );
  }

  Future<void> _editProfile(
    BuildContext context,
    UserProfile profile,
    MedicineRepository repository,
  ) async {
    var name = profile.fullName;
    var phone = profile.phoneNumber;
    var age = profile.ageAt(DateTime.now())?.toString() ?? '';
    var gender = profile.gender;
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit profil'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: name,
                  onChanged: (value) => name = value,
                  decoration: const InputDecoration(labelText: 'Nama lengkap'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: phone,
                  onChanged: (value) => phone = value,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Nomor telepon'),
                ),
                if (isPatient) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: age,
                    onChanged: (value) => age = value,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Umur',
                      suffixText: 'tahun',
                      prefixIcon: Icon(Icons.cake_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: gender,
                    decoration: const InputDecoration(
                      labelText: 'Jenis kelamin',
                      prefixIcon: Icon(Icons.wc_rounded),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'male', child: Text('Laki-laki')),
                      DropdownMenuItem(
                        value: 'female',
                        child: Text('Perempuan'),
                      ),
                    ],
                    onChanged: (value) => setDialogState(() => gender = value),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
    if (save == true && name.trim().isNotEmpty) {
      final parsedAge = int.tryParse(age.trim());
      if (isPatient &&
          (parsedAge == null ||
              parsedAge < 0 ||
              parsedAge > 120 ||
              gender == null)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Umur harus 0–120 tahun dan jenis kelamin wajib dipilih.',
              ),
            ),
          );
        }
        return;
      }
      await repository.updateProfile(
        userId: profile.id,
        fullName: name,
        phoneNumber: phone,
        age: isPatient ? parsedAge : null,
        gender: isPatient ? gender : null,
      );
    }
  }

  Future<void> _changePassword(BuildContext context, String email) async {
    if (email.isEmpty) return;
    await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Tautan atur ulang kata sandi dikirim ke $email.'),
        ),
      );
    }
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label, style: Theme.of(context).textTheme.labelMedium),
      subtitle: Text(value.isEmpty ? 'Belum tercatat' : value),
      trailing: trailing,
    );
  }
}
