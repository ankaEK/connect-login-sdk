import 'package:flutter/material.dart';
import 'package:login_with_connect/login_with_connect.dart';

/// Replace with your Connect Persona OAuth client ID.
const String kClientId = 'YOUR_CLIENT_ID';

/// Must match the redirect URI registered in Connect and in Android/iOS
/// deep-link config (see example/README.md).
const String kRedirectUri = 'loginwithconnect://oauth/callback';

void main() {
  runApp(const MaterialApp(title: 'Connect Sign In', home: SignInDemo()));
}

/// Minimal demo of [ConnectPersonaAuth.signIn].
class SignInDemo extends StatefulWidget {
  const SignInDemo({super.key});

  @override
  State<SignInDemo> createState() => _SignInDemoState();
}

class _SignInDemoState extends State<SignInDemo> {
  bool _signingIn = false;
  String _status = 'Not signed in.';
  String? _authCode;
  String? _errorMessage;

  Future<void> _handleSignIn() async {
    if (_signingIn) return;

    setState(() {
      _signingIn = true;
      _authCode = null;
      _errorMessage = null;
      _status = 'Starting sign-in…';
    });

    final auth = ConnectPersonaAuth(
      clientId: kClientId,
      redirectUri: kRedirectUri,
      environment: ConnectEnvironment.uat,
    );

    try {
      // #docregion SignIn
      final code = await auth.signIn(
        onExternalAppLaunched: () {
          if (!mounted) return;
          setState(() => _status = 'Waiting for Connect Persona…');
        },
        onFellBackToWeb: () {
          if (!mounted) return;
          setState(() => _status = 'Using web sign-in…');
        },
      );
      // #enddocregion SignIn

      if (!mounted) return;
      setState(() {
        _authCode = code;
        _status = 'Signed in. Exchange this code on your backend.';
        _errorMessage = null;
      });
    } on ConnectAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _authCode = null;
        _status = 'Sign-in failed.';
        _errorMessage = '${e.code}: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _authCode = null;
        _status = 'Sign-in failed.';
        _errorMessage = e.toString();
      });
    } finally {
      await auth.dispose();
      if (mounted) setState(() => _signingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect Sign In')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_status, textAlign: TextAlign.center),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (_authCode != null) ...[
                const SizedBox(height: 12),
                SelectableText(_authCode!, textAlign: TextAlign.center),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _signingIn ? null : _handleSignIn,
                child: Text(_signingIn ? 'SIGNING IN…' : 'SIGN IN'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
