import 'package:flutter/material.dart';
import 'package:login_with_connect/login_with_connect.dart';

/// Replace with your Connect Persona OAuth client ID (from the developer portal).
const String kClientId = 'client_e48a3e01-8481-4cad-8dc0-f97f19004dc6';

/// Host-supplied OAuth scope. Register matching scopes on the portal client.
const String kScope = 'profile.basic';

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

  String _tokenCurlFor(String code) {
    return '''
curl -X 'POST' \\
  'https://dev.connectpersona.com/api/v1/oauth/token' \\
  -H 'accept: application/json' \\
  -H 'Content-Type: application/json' \\
  -d '{
  "client_id": "$kClientId",
  "client_secret": "*****",
  "code": "$code"
}'
'''
        .trim();
  }

  static const _tokenResponseSample = '''
{
  "message": "string",
  "error": 0,
  "data": {
    "access_token": "string",
    "expires_in": 0,
    "refresh_token": "string",
    "token_type": "string",
    "user": {
      "id": "",
      "name": "",
      "email": "",
      "image": ""
    }
  }
}
''';

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
      scope: kScope,
      environment: ConnectEnvironment.dev,
    );

    try {
      final code = await auth.signIn(
        onExternalAppLaunched: () {
          if (!mounted) return;
          setState(() => _status = 'Waiting for Connect Persona…');
        },
        onFellBackToWeb: () {
          if (!mounted) return;
          setState(() => _status = 'Using web sign-in…');
        },
        onAppLaunchFailed: (reason) {
          if (!mounted) return;
          setState(() => _status = 'App launch failed: $reason');
        },
      );

      if (!mounted) return;
      setState(() {
        _authCode = code;
        _status = 'Signed in';
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
    final code = _authCode;

    return Scaffold(
      appBar: AppBar(title: const Text('Connect Sign In')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                if (code != null) ...[
                  const SizedBox(height: 20),
                  SelectableText(
                    'Code: $code',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Valid for 1 minute',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Use the following request to fetch full user details',
                  ),
                  const SizedBox(height: 12),
                  const Text('CURL:'),
                  const SizedBox(height: 8),
                  _CodeBlock(text: _tokenCurlFor(code)),
                  const SizedBox(height: 16),
                  const Text('Response:'),
                  const SizedBox(height: 8),
                  const _CodeBlock(text: _tokenResponseSample),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _signingIn ? null : _handleSignIn,
                  child: Text(
                    _signingIn
                        ? 'SIGNING IN…'
                        : code != null
                        ? 'SIGN IN AGAIN'
                        : 'SIGN IN',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          text.trim(),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Color(0xFFE8E8E8),
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
