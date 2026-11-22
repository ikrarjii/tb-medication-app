import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/treatment_plan.dart';
import '../models/user_profile.dart';
import 'push_notification_service.dart';
import 'reminder_service.dart';

enum UserRole {
  patient,
  caregiver;

  String get label => switch (this) {
    UserRole.patient => 'Pasien',
    UserRole.caregiver => 'Pengawas',
  };
}

class AuthFailure implements Exception {
  const AuthFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class AuthService extends ChangeNotifier {
  AuthService({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : _auth = auth ?? FirebaseAuth.instance,
      _firestore = firestore ?? FirebaseFirestore.instance {
    _authSubscription = _auth.authStateChanges().listen(_handleAuthChanged);
  }

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  late final StreamSubscription<User?> _authSubscription;

  User? _user;
  UserRole? _role;
  bool _isLoading = true;
  bool _isInitializing = true;
  bool _isAuthOperation = false;
  String? _errorMessage;

  User? get user => _user;
  UserRole? get role => _role;
  bool get isLoading => _isLoading;
  bool get isInitializing => _isInitializing;
  String? get errorMessage => _errorMessage;
  bool get isAuthenticated => _user != null && _role != null;

  Future<void> signIn({
    required String email,
    required String password,
    required UserRole expectedRole,
  }) async {
    _beginOperation();
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final role = await _fetchRole(credential.user!.uid);
      if (role == UserRole.patient) {
        await _ensurePatientCode(credential.user!.uid);
      }

      if (role != expectedRole) {
        await _auth.signOut();
        throw AuthFailure(
          'Akun ini terdaftar sebagai ${role.label.toLowerCase()}. '
          'Silakan kembali dan pilih ${role.label}.',
        );
      }

      _user = credential.user;
      _role = role;
    } on FirebaseAuthException catch (error) {
      _errorMessage = _friendlyAuthMessage(error);
      throw AuthFailure(_errorMessage!);
    } on FirebaseException catch (error) {
      _errorMessage = _friendlyFirebaseMessage(error);
      await _safeSignOut();
      throw AuthFailure(_errorMessage!);
    } on StateError catch (error) {
      _errorMessage = error.message;
      await _safeSignOut();
      throw AuthFailure(_errorMessage!);
    } on AuthFailure catch (error) {
      _errorMessage = error.message;
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<void> register({
    required String fullName,
    required String email,
    required String phoneNumber,
    required String password,
    required UserRole role,
    int? age,
    String? gender,
    String? treatmentGroup,
  }) async {
    _beginOperation();
    User? createdUser;

    try {
      if (password.length < 8 ||
          !RegExp(r'[A-Z]').hasMatch(password) ||
          !RegExp(r'[a-z]').hasMatch(password) ||
          !RegExp(r'[0-9]').hasMatch(password)) {
        throw const AuthFailure(
          'Kata sandi minimal 8 karakter dan harus memuat huruf besar, huruf kecil, serta angka.',
        );
      }
      if (role == UserRole.patient &&
          (age == null ||
              age < 0 ||
              age > 120 ||
              !const ['male', 'female'].contains(gender) ||
              !const [
                TreatmentPlan.group1,
                TreatmentPlan.otherGroup,
              ].contains(treatmentGroup))) {
        throw const AuthFailure('Data pasien belum lengkap atau tidak valid.');
      }
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      createdUser = credential.user!;
      final patientCode = role == UserRole.patient
          ? await _createPatientProfile(
              userId: createdUser.uid,
              fullName: fullName,
              email: email,
              phoneNumber: phoneNumber,
              age: age!,
              gender: gender!,
              treatmentGroup: treatmentGroup!,
            )
          : null;
      if (patientCode == null) {
        await _firestore.collection('users').doc(createdUser.uid).set({
          'fullName': fullName.trim(),
          'email': email.trim().toLowerCase(),
          'phoneNumber': phoneNumber.trim(),
          'role': role.name,
          'notificationsEnabled': true,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      try {
        await createdUser.updateDisplayName(fullName.trim());
      } on FirebaseAuthException {
        // The Firestore profile remains the source of truth for the full name.
      }

      _user = createdUser;
      _role = role;
    } on FirebaseAuthException catch (error) {
      _errorMessage = _friendlyAuthMessage(error);
      throw AuthFailure(_errorMessage!);
    } on FirebaseException catch (error) {
      _errorMessage = _friendlyFirebaseMessage(error);
      if (createdUser != null) {
        try {
          await createdUser.delete();
        } on FirebaseAuthException {
          // Continue signing out and report the original profile error.
        }
      }
      await _safeSignOut();
      throw AuthFailure(_errorMessage!);
    } finally {
      _endOperation();
    }
  }

  Future<String> _createPatientProfile({
    required String userId,
    required String fullName,
    required String email,
    required String phoneNumber,
    required int age,
    required String gender,
    required String treatmentGroup,
  }) async {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();

    for (var attempt = 0; attempt < 8; attempt++) {
      final code = List.generate(
        8,
        (_) => alphabet[random.nextInt(alphabet.length)],
      ).join();
      final codeRef = _firestore.collection('patientCodes').doc(code);
      final userRef = _firestore.collection('users').doc(userId);
      try {
        await _firestore.runTransaction((transaction) async {
          final existing = await transaction.get(codeRef);
          if (existing.exists) throw StateError('Kode pasien sudah digunakan.');
          transaction.set(userRef, {
            'fullName': fullName.trim(),
            'email': email.trim().toLowerCase(),
            'phoneNumber': phoneNumber.trim(),
            'age': age,
            'ageCategory': ageCategoryFor(age),
            'gender': gender,
            'role': UserRole.patient.name,
            'patientCode': code,
            'treatmentGroup': treatmentGroup,
            'treatmentStartedAt': FieldValue.serverTimestamp(),
            'notificationsEnabled': true,
            'createdAt': FieldValue.serverTimestamp(),
          });
          transaction.set(codeRef, {
            'patientId': userId,
            'patientName': fullName.trim(),
            'createdAt': FieldValue.serverTimestamp(),
          });
        });
        return code;
      } on StateError {
        // A collision is extremely unlikely; generate a fresh code and retry.
      }
    }
    throw const AuthFailure('Tidak dapat membuat kode pasien. Coba lagi.');
  }

  Future<void> sendPasswordResetEmail(String email) async {
    _beginOperation();
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (error) {
      _errorMessage = _friendlyAuthMessage(error);
      throw AuthFailure(_errorMessage!);
    } finally {
      _endOperation();
    }
  }

  Future<void> signOut() async {
    _setLoading(true);
    try {
      await PushNotificationService.instance.stopAndUnregister();
      await ReminderService.instance.clearAllReminders();
      await _auth.signOut();
    } catch (_) {
      _setLoading(false);
      rethrow;
    }
  }

  Future<UserRole> _fetchRole(String uid) async {
    final snapshot = await _firestore.collection('users').doc(uid).get();
    if (!snapshot.exists) {
      throw StateError('Profil pengguna untuk akun ini tidak ditemukan.');
    }

    return switch (snapshot.data()?['role']) {
      'patient' => UserRole.patient,
      'caregiver' => UserRole.caregiver,
      _ => throw StateError('Peran akun ini tidak didukung.'),
    };
  }

  Future<void> _ensurePatientCode(String userId) async {
    final userRef = _firestore.collection('users').doc(userId);
    final current = await userRef.get();
    final currentData = current.data() ?? const <String, dynamic>{};
    final currentCode = currentData['patientCode'] as String?;
    final treatmentDefaults = <String, Object>{};
    if (currentData['treatmentGroup'] == null) {
      treatmentDefaults['treatmentGroup'] = 'group1';
    }
    if (currentData['treatmentStartedAt'] == null) {
      treatmentDefaults['treatmentStartedAt'] = FieldValue.serverTimestamp();
    }
    if (treatmentDefaults.isNotEmpty) {
      treatmentDefaults['updatedAt'] = FieldValue.serverTimestamp();
      await userRef.update(treatmentDefaults);
    }
    if (currentCode != null && currentCode.isNotEmpty) return;

    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    for (var attempt = 0; attempt < 8; attempt++) {
      final code = List.generate(
        8,
        (_) => alphabet[random.nextInt(alphabet.length)],
      ).join();
      final codeRef = _firestore.collection('patientCodes').doc(code);
      try {
        await _firestore.runTransaction((transaction) async {
          final user = await transaction.get(userRef);
          final existingCode = user.data()?['patientCode'] as String?;
          if (existingCode != null && existingCode.isNotEmpty) return;
          final existing = await transaction.get(codeRef);
          if (existing.exists) throw StateError('Kode pasien sudah digunakan.');
          transaction.update(userRef, {
            'patientCode': code,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          transaction.set(codeRef, {
            'patientId': userId,
            'patientName': user.data()?['fullName'] ?? 'Pasien',
            'createdAt': FieldValue.serverTimestamp(),
          });
        });
        return;
      } on StateError {
        // Generate another code if the candidate already exists.
      }
    }
    throw StateError('Tidak dapat membuat kode pasien untuk akun ini.');
  }

  Future<void> _handleAuthChanged(User? user) async {
    if (_isAuthOperation) return;

    _user = user;
    _role = null;
    _errorMessage = null;

    if (user == null) {
      _isInitializing = false;
      _setLoading(false);
      return;
    }

    _setLoading(true);
    try {
      _role = await _fetchRole(user.uid);
      if (_role == UserRole.patient) {
        await _ensurePatientCode(user.uid);
      }
    } on FirebaseException catch (error) {
      _errorMessage = _friendlyFirebaseMessage(error);
    } on StateError catch (error) {
      _errorMessage = error.message;
    } finally {
      _isInitializing = false;
      _setLoading(false);
    }
  }

  void _beginOperation() {
    _isAuthOperation = true;
    _errorMessage = null;
    _setLoading(true);
  }

  void _endOperation() {
    _isAuthOperation = false;
    _setLoading(false);
  }

  Future<void> _safeSignOut() async {
    try {
      await _auth.signOut();
    } catch (_) {
      // Preserve the original authentication/profile error.
    }
    _user = null;
    _role = null;
  }

  String _friendlyAuthMessage(FirebaseAuthException error) {
    return switch (error.code) {
      'invalid-credential' ||
      'wrong-password' ||
      'user-not-found' => 'Email atau kata sandi salah.',
      'email-already-in-use' => 'Email ini sudah digunakan oleh akun lain.',
      'invalid-email' => 'Masukkan alamat email yang valid.',
      'weak-password' =>
        'Gunakan kata sandi minimal 8 karakter dengan huruf besar, huruf kecil, dan angka.',
      'too-many-requests' => 'Terlalu banyak percobaan. Coba lagi nanti.',
      'network-request-failed' =>
        'Tidak ada koneksi internet. Periksa jaringan lalu coba lagi.',
      _ => 'Autentikasi gagal. Silakan coba lagi.',
    };
  }

  String _friendlyFirebaseMessage(FirebaseException error) {
    return switch (error.code) {
      'permission-denied' =>
        'Akses database ditolak. Pastikan aturan Firestore sudah diterapkan.',
      'unavailable' =>
        'Layanan sedang tidak tersedia. Periksa koneksi lalu coba lagi.',
      'deadline-exceeded' =>
        'Permintaan terlalu lama. Periksa koneksi lalu coba lagi.',
      _ => 'Terjadi kesalahan saat memuat data.',
    };
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    super.dispose();
  }
}
