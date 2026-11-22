import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/caregiver_home_screen.dart';
import 'screens/patient_home_screen.dart';
import 'screens/role_selection_screen.dart';
import 'screens/splash_screen.dart';
import 'firebase_environment.dart';
import 'services/auth_service.dart';
import 'services/push_notification_service.dart';
import 'services/reminder_service.dart';

class Wrapper extends StatelessWidget {
  const Wrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();

    if (auth.isInitializing) {
      return const SplashScreen();
    }
    if (!auth.isAuthenticated) return const RoleSelectionScreen();

    return _AuthenticatedHome(userId: auth.user!.uid, role: auth.role!);
  }
}

/// Owns notification subscriptions outside [Wrapper.build], so authentication
/// changes never mutate plugin/stream state while Provider is rebuilding its
/// dependent widget tree.
class _AuthenticatedHome extends StatefulWidget {
  const _AuthenticatedHome({required this.userId, required this.role});

  final String userId;
  final UserRole role;

  @override
  State<_AuthenticatedHome> createState() => _AuthenticatedHomeState();
}

class _AuthenticatedHomeState extends State<_AuthenticatedHome> {
  @override
  void initState() {
    super.initState();
    unawaited(_configureNativePatient());
    if (!FirebaseEnvironment.useEmulator) {
      PushNotificationService.instance.startForUser(widget.userId);
    }
  }

  @override
  void didUpdateWidget(covariant _AuthenticatedHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId || oldWidget.role != widget.role) {
      unawaited(_configureNativePatient());
      if (!FirebaseEnvironment.useEmulator) {
      PushNotificationService.instance.startForUser(widget.userId);
    }
    }
  }

  @override
  void dispose() {
    PushNotificationService.instance.stop();
    unawaited(ReminderService.instance.clearAllReminders());
    super.dispose();
  }

  Future<void> _configureNativePatient() async {
    final patientId = widget.role == UserRole.patient ? widget.userId : null;
    await ReminderService.instance.setActivePatient(patientId);
    if (patientId == null) {
      await ReminderService.instance.clearAllReminders();
    }
  }

  @override
  Widget build(BuildContext context) => switch (widget.role) {
    UserRole.patient => const PatientHomeScreen(),
    UserRole.caregiver => const CaregiverHomeScreen(),
  };
}
