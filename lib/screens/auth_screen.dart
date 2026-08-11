import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/treatment_plan.dart';
import '../services/auth_service.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.role});

  final UserRole role;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _loginFormKey = GlobalKey<FormState>();
  final _registerFormKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _fullNameController = TextEditingController();
  final _registerEmailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _ageController = TextEditingController();
  final _registerPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _showRegister = false;
  bool _obscureLoginPassword = true;
  bool _obscureRegisterPassword = true;
  bool _obscureConfirmPassword = true;
  String? _selectedGender;
  String? _selectedTreatmentGroup;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _fullNameController.dispose();
    _registerEmailController.dispose();
    _phoneController.dispose();
    _ageController.dispose();
    _registerPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_loginFormKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    try {
      await context.read<AuthService>().signIn(
        email: _emailController.text,
        password: _passwordController.text,
        expectedRole: widget.role,
      );
      if (!mounted) return;
      await _returnToRootAfterAuth();
    } on AuthFailure catch (error) {
      _showError(error.message);
    }
  }

  Future<void> _register() async {
    if (!_registerFormKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    try {
      await context.read<AuthService>().register(
        fullName: _fullNameController.text,
        email: _registerEmailController.text,
        phoneNumber: _phoneController.text,
        password: _registerPasswordController.text,
        role: widget.role,
        age: widget.role == UserRole.patient
            ? int.tryParse(_ageController.text)
            : null,
        gender: widget.role == UserRole.patient ? _selectedGender : null,
        treatmentGroup: widget.role == UserRole.patient
            ? _selectedTreatmentGroup
            : null,
      );
      if (!mounted) return;
      await _returnToRootAfterAuth();
    } on AuthFailure catch (error) {
      _showError(error.message);
    }
  }

  Future<void> _returnToRootAfterAuth() async {
    // AuthService notifies Provider before its Future completes. Waiting for
    // that rebuild prevents route removal while inherited dependents are still
    // being updated in the same frame.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _forgotPassword() async {
    var emailValue = _emailController.text;
    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.lock_reset_rounded),
        title: const Text('Atur ulang kata sandi'),
        content: TextFormField(
          initialValue: emailValue,
          onChanged: (value) => emailValue = value,
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Alamat email',
            prefixIcon: Icon(Icons.email_outlined),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, emailValue),
            child: const Text('Kirim tautan'),
          ),
        ],
      ),
    );

    if (email == null) return;
    if (!_isValidEmail(email)) {
      _showError('Masukkan alamat email yang valid.');
      return;
    }
    if (!mounted) return;
    try {
      await context.read<AuthService>().sendPasswordResetEmail(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tautan atur ulang kata sandi telah dikirim.'),
        ),
      );
    } on AuthFailure catch (error) {
      _showError(error.message);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  bool _isValidEmail(String value) {
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim());
  }

  String? _required(String? value, String field) {
    if (value == null || value.trim().isEmpty) return '$field wajib diisi.';
    return null;
  }

  String? _validateRegistrationPassword(String? value) {
    if (value == null || value.isEmpty) return 'Kata sandi wajib diisi.';
    if (value.length < 8) return 'Kata sandi minimal 8 karakter.';
    if (!RegExp(r'[A-Z]').hasMatch(value) ||
        !RegExp(r'[a-z]').hasMatch(value) ||
        !RegExp(r'[0-9]').hasMatch(value)) {
      return 'Gunakan huruf besar, huruf kecil, dan angka.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = context.select<AuthService, bool>(
      (service) => service.isLoading,
    );
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Ganti peran',
          onPressed: isLoading ? null : () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text('Akses ${widget.role.label}'),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFE6F7F1), Color(0xFFF8FBFA)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x1F08745F),
                            blurRadius: 24,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Icon(
                        widget.role == UserRole.patient
                            ? Icons.health_and_safety_rounded
                            : Icons.volunteer_activism_rounded,
                        size: 38,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      _showRegister
                          ? 'Buat akun Anda'
                          : 'Selamat datang kembali',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _showRegister
                          ? 'Daftar sebagai ${widget.role.label.toLowerCase()}'
                          : 'Masuk ke dashboard ${widget.role.label.toLowerCase()}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 28),
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: _showRegister
                              ? _buildRegisterForm(isLoading)
                              : _buildLoginForm(isLoading),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginForm(bool isLoading) {
    return Form(
      key: _loginFormKey,
      child: Column(
        key: const ValueKey('login'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _emailController,
            enabled: !isLoading,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email',
              prefixIcon: Icon(Icons.email_outlined),
            ),
            validator: (value) => value == null || !_isValidEmail(value)
                ? 'Masukkan alamat email yang valid.'
                : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _passwordController,
            enabled: !isLoading,
            obscureText: _obscureLoginPassword,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(
              labelText: 'Kata sandi',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                onPressed: () => setState(
                  () => _obscureLoginPassword = !_obscureLoginPassword,
                ),
                icon: Icon(
                  _obscureLoginPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
            validator: (value) => _required(value, 'Kata sandi'),
            onFieldSubmitted: isLoading ? null : (_) => _login(),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: isLoading ? null : _forgotPassword,
              child: const Text('Lupa kata sandi?'),
            ),
          ),
          const SizedBox(height: 8),
          _SubmitButton(
            isLoading: isLoading,
            label: 'Masuk sebagai ${widget.role.label}',
            onPressed: _login,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: isLoading
                ? null
                : () => setState(() => _showRegister = true),
            child: const Text('Buat akun baru'),
          ),
        ],
      ),
    );
  }

  Widget _buildRegisterForm(bool isLoading) {
    return Form(
      key: _registerFormKey,
      child: Column(
        key: const ValueKey('register'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _fullNameController,
            enabled: !isLoading,
            textCapitalization: TextCapitalization.words,
            autofillHints: const [AutofillHints.name],
            decoration: const InputDecoration(
              labelText: 'Nama lengkap',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
            validator: (value) => _required(value, 'Nama lengkap'),
          ),
          const SizedBox(height: 14),
          if (widget.role == UserRole.patient) ...[
            TextFormField(
              controller: _ageController,
              enabled: !isLoading,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Umur',
                suffixText: 'tahun',
                prefixIcon: Icon(Icons.cake_outlined),
              ),
              validator: (value) {
                final age = int.tryParse(value?.trim() ?? '');
                if (age == null) return 'Umur wajib berupa angka.';
                if (age < 0 || age > 120) {
                  return 'Umur harus antara 0 sampai 120 tahun.';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _selectedGender,
              decoration: const InputDecoration(
                labelText: 'Jenis kelamin',
                prefixIcon: Icon(Icons.wc_rounded),
              ),
              items: const [
                DropdownMenuItem(value: 'male', child: Text('Laki-laki')),
                DropdownMenuItem(value: 'female', child: Text('Perempuan')),
              ],
              onChanged: isLoading
                  ? null
                  : (value) => setState(() => _selectedGender = value),
              validator: (value) =>
                  value == null ? 'Jenis kelamin wajib dipilih.' : null,
            ),
            const SizedBox(height: 14),
          ],
          TextFormField(
            controller: _registerEmailController,
            enabled: !isLoading,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email',
              prefixIcon: Icon(Icons.email_outlined),
            ),
            validator: (value) => value == null || !_isValidEmail(value)
                ? 'Masukkan alamat email yang valid.'
                : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _phoneController,
            enabled: !isLoading,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: const InputDecoration(
              labelText: 'Nomor telepon',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
            validator: (value) {
              final requiredError = _required(value, 'Nomor telepon');
              if (requiredError != null) return requiredError;
              final digits = value!.replaceAll(RegExp(r'\D'), '');
              return digits.length < 8
                  ? 'Masukkan nomor telepon yang valid.'
                  : null;
            },
          ),
          const SizedBox(height: 14),
          if (widget.role == UserRole.patient) ...[
            DropdownButtonFormField<String>(
              initialValue: _selectedTreatmentGroup,
              decoration: const InputDecoration(
                labelText: 'Golongan pengobatan',
                prefixIcon: Icon(Icons.medical_information_outlined),
              ),
              items: const [
                DropdownMenuItem(
                  value: TreatmentPlan.group1,
                  child: Text('Golongan 1'),
                ),
                DropdownMenuItem(
                  value: TreatmentPlan.otherGroup,
                  child: Text('Golongan Lain'),
                ),
              ],
              onChanged: isLoading
                  ? null
                  : (value) => setState(() => _selectedTreatmentGroup = value),
              validator: (value) =>
                  value == null ? 'Golongan pengobatan wajib dipilih.' : null,
            ),
            const SizedBox(height: 14),
          ],
          DropdownButtonFormField<UserRole>(
            initialValue: widget.role,
            decoration: const InputDecoration(
              labelText: 'Peran pengguna',
              prefixIcon: Icon(Icons.groups_outlined),
            ),
            items: [
              DropdownMenuItem(
                value: widget.role,
                child: Text(widget.role.label),
              ),
            ],
            onChanged: null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _registerPasswordController,
            enabled: !isLoading,
            obscureText: _obscureRegisterPassword,
            autofillHints: const [AutofillHints.newPassword],
            decoration: InputDecoration(
              labelText: 'Kata sandi',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                onPressed: () => setState(
                  () => _obscureRegisterPassword = !_obscureRegisterPassword,
                ),
                icon: Icon(
                  _obscureRegisterPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
            validator: _validateRegistrationPassword,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _confirmPasswordController,
            enabled: !isLoading,
            obscureText: _obscureConfirmPassword,
            autofillHints: const [AutofillHints.newPassword],
            decoration: InputDecoration(
              labelText: 'Konfirmasi kata sandi',
              prefixIcon: const Icon(Icons.lock_reset_outlined),
              suffixIcon: IconButton(
                onPressed: () => setState(
                  () => _obscureConfirmPassword = !_obscureConfirmPassword,
                ),
                icon: Icon(
                  _obscureConfirmPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
            validator: (value) => value != _registerPasswordController.text
                ? 'Konfirmasi kata sandi tidak cocok.'
                : null,
            onFieldSubmitted: isLoading ? null : (_) => _register(),
          ),
          const SizedBox(height: 24),
          _SubmitButton(
            isLoading: isLoading,
            label: 'Daftar sebagai ${widget.role.label}',
            onPressed: _register,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: isLoading
                ? null
                : () => setState(() => _showRegister = false),
            child: const Text('Sudah punya akun? Masuk'),
          ),
        ],
      ),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.isLoading,
    required this.label,
    required this.onPressed,
  });

  final bool isLoading;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: isLoading ? null : onPressed,
      child: isLoading
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }
}
