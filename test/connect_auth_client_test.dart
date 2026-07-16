import 'package:flutter_test/flutter_test.dart';
import 'package:login_with_connect/login_with_connect.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ConnectPersonaAuth buildAuth({
    ConnectEnvironment environment = ConnectEnvironment.dev,
    String? webAuthorizeBaseUrl,
    Future<bool> Function(Uri uri, {LaunchMode mode})? launchUrlFn,
    WebAuthorizeOpener? webAuthorizeOpener,
  }) {
    return ConnectPersonaAuth(
      clientId: 'client_test',
      redirectUri: 'https://dev.parking.lahvplus.com/check_account',
      environment: environment,
      webAuthorizeBaseUrl: webAuthorizeBaseUrl,
      launchUrlFn: launchUrlFn,
      webAuthorizeOpener: webAuthorizeOpener,
    );
  }

  group('ConnectEnvironment', () {
    test('maps flavor-like envs to Connect hosts', () {
      expect(
        ConnectEnvironment.dev.authHost,
        'https://dev.connectpersona.com',
      );
      expect(
        ConnectEnvironment.uat.authHost,
        'https://uat.connectpersona.com',
      );
      expect(
        ConnectEnvironment.prod.authHost,
        'https://app.connectpersona.com',
      );
    });

    test('authorizeBaseUri uses oauth authorize path', () {
      expect(
        ConnectEnvironment.dev.authorizeBaseUri.toString(),
        'https://dev.connectpersona.com/api/v1/oauth/authorize',
      );
    });
  });

  group('buildWebAuthorizeUri', () {
    test('uses environment host and merges webQueryParams', () {
      final auth = buildAuth();
      final uri = auth.buildWebAuthorizeUri(
        webQueryParams: {'role': 'O', 'signup': 'false'},
      );

      expect(uri.scheme, 'https');
      expect(uri.host, 'dev.connectpersona.com');
      expect(uri.path, '/api/v1/oauth/authorize');
      expect(uri.queryParameters['client_id'], 'client_test');
      expect(
        uri.queryParameters['redirect_uri'],
        'https://dev.parking.lahvplus.com/check_account',
      );
      expect(uri.queryParameters['scope'], 'profile.basic');
      expect(uri.queryParameters['response_type'], 'code');
      expect(uri.queryParameters['role'], 'O');
      expect(uri.queryParameters['signup'], 'false');
    });

    test('webAuthorizeBaseUrl override wins over environment', () {
      final auth = buildAuth(
        environment: ConnectEnvironment.prod,
        webAuthorizeBaseUrl:
            'https://custom.example.com/oauth/authorize?foo=1',
      );
      final uri = auth.buildWebAuthorizeUri(
        webQueryParams: {'role': 'I'},
      );

      expect(uri.host, 'custom.example.com');
      expect(uri.queryParameters['foo'], '1');
      expect(uri.queryParameters['role'], 'I');
      expect(uri.queryParameters['client_id'], 'client_test');
    });

    test('ignores reserved oauth keys in webQueryParams', () {
      final auth = buildAuth();
      final uri = auth.buildWebAuthorizeUri(
        webQueryParams: {
          'client_id': 'attacker',
          'redirect_uri': 'https://evil.example',
          'response_type': 'token',
          'role': 'B',
        },
      );

      expect(uri.queryParameters['client_id'], 'client_test');
      expect(
        uri.queryParameters['redirect_uri'],
        'https://dev.parking.lahvplus.com/check_account',
      );
      expect(uri.queryParameters['response_type'], 'code');
      expect(uri.queryParameters['role'], 'B');
    });
  });

  group('signIn routing', () {
    test('uses app path when launch succeeds (no web fallback)', () async {
      var webOpened = false;
      final shortAuth = ConnectPersonaAuth(
        clientId: 'client_test',
        redirectUri: 'https://dev.parking.lahvplus.com/check_account',
        environment: ConnectEnvironment.dev,
        signInTimeout: const Duration(milliseconds: 80),
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async {
          expect(uri.scheme, 'connectpersona');
          return true;
        },
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          webOpened = true;
          return 'https://dev.parking.lahvplus.com/check_account?code=nope';
        },
      );

      await expectLater(
        shortAuth.signIn(webQueryParams: {'role': 'O'}),
        throwsA(
          isA<ConnectAuthException>().having(
            (e) => e.code,
            'code',
            ConnectAuthException.timeout,
          ),
        ),
      );
      expect(webOpened, isFalse);
      await shortAuth.dispose();
    });

    test('falls back to SDK web opener when app missing', () async {
      Uri? openedUrl;
      final auth = buildAuth(
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => false,
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          openedUrl = url;
          expect(scheme, 'https');
          expect(httpsHost, 'dev.parking.lahvplus.com');
          expect(httpsPath, '/check_account');
          return 'https://dev.parking.lahvplus.com/check_account?code=abc123';
        },
      );

      final code = await auth.signIn(
        webQueryParams: {'role': 'O', 'signup': 'false'},
      );

      expect(code, 'abc123');
      expect(openedUrl?.queryParameters['role'], 'O');
      expect(openedUrl?.queryParameters['signup'], 'false');
      await auth.dispose();
    });

    test('uses onOpenWebAuthorize escape hatch when provided', () async {
      final auth = buildAuth(
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => false,
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          fail('default web opener should not run');
        },
      );

      final code = await auth.signIn(
        webQueryParams: {'role': 'B'},
        onOpenWebAuthorize: (url) async {
          expect(url.queryParameters['role'], 'B');
          return 'host-code';
        },
      );

      expect(code, 'host-code');
      await auth.dispose();
    });

    test('rejects empty code from web callback', () async {
      final auth = buildAuth(
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => false,
      );

      await expectLater(
        auth.signIn(
          onOpenWebAuthorize: (url) async => '',
        ),
        throwsA(
          isA<ConnectAuthException>().having(
            (e) => e.code,
            'code',
            ConnectAuthException.invalidResponse,
          ),
        ),
      );
      await auth.dispose();
    });
  });

  group('parseAuthorizationCode', () {
    test('returns code for matching redirect', () {
      final auth = buildAuth();
      final code = auth.parseAuthorizationCode(
        Uri.parse(
          'https://dev.parking.lahvplus.com/check_account?code=xyz',
        ),
      );
      expect(code, 'xyz');
    });

    test('maps access_denied', () {
      final auth = buildAuth();
      expect(
        () => auth.parseAuthorizationCode(
          Uri.parse(
            'https://dev.parking.lahvplus.com/check_account?error=access_denied',
          ),
        ),
        throwsA(
          isA<ConnectAuthException>().having(
            (e) => e.code,
            'code',
            ConnectAuthException.accessDenied,
          ),
        ),
      );
    });
  });
}
