import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:app_links_platform_interface/app_links_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_with_connect/login_with_connect.dart';
import 'package:url_launcher/url_launcher.dart';

const _redirectUri = 'https://dev.parking.lahvplus.com/check_account';

String _redirectWithCode(String code, {String? state}) {
  final query = state == null ? 'code=$code' : 'code=$code&state=$state';
  return '$_redirectUri?$query';
}

class FakeAppLinksPlatform extends AppLinksPlatform {
  FakeAppLinksPlatform({
    this.initialLink,
    this.latestLink,
    Stream<Uri>? uriLinkStream,
  }) : _uriLinkStream = uriLinkStream ?? const Stream.empty();

  Uri? initialLink;
  Uri? latestLink;
  final Stream<Uri> _uriLinkStream;

  @override
  Future<Uri?> getInitialLink() async => initialLink;

  @override
  Future<Uri?> getLatestLink() async => latestLink;

  @override
  Stream<Uri> get uriLinkStream => _uriLinkStream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLinksPlatform originalAppLinksPlatform;

  setUp(() {
    originalAppLinksPlatform = AppLinksPlatform.instance;
  });

  tearDown(() {
    AppLinksPlatform.instance = originalAppLinksPlatform;
  });

  ConnectPersonaAuth buildAuth({
    ConnectEnvironment environment = ConnectEnvironment.dev,
    String? webAuthorizeBaseUrl,
    AppLinks? appLinks,
    Future<bool> Function(Uri uri, {LaunchMode mode})? launchUrlFn,
    Future<bool> Function(Uri uri)? canLaunchUrlFn,
    Future<bool> Function(Duration timeout)? waitForAppBackgroundFn,
    WebAuthorizeOpener? webAuthorizeOpener,
  }) {
    return ConnectPersonaAuth(
      clientId: 'client_test',
      redirectUri: _redirectUri,
      environment: environment,
      webAuthorizeBaseUrl: webAuthorizeBaseUrl,
      appLinks: appLinks,
      launchUrlFn: launchUrlFn,
      canLaunchUrlFn: canLaunchUrlFn ?? ((_) async => true),
      waitForAppBackgroundFn: waitForAppBackgroundFn,
      webAuthorizeOpener: webAuthorizeOpener,
    );
  }

  group('constructor validation', () {
    test('throws for empty clientId', () {
      expect(
        () => ConnectPersonaAuth(
          clientId: '',
          redirectUri: _redirectUri,
          environment: ConnectEnvironment.dev,
        ),
        throwsArgumentError,
      );
    });

    test('throws for empty redirectUri', () {
      expect(
        () => ConnectPersonaAuth(
          clientId: 'client_test',
          redirectUri: '',
          environment: ConnectEnvironment.dev,
        ),
        throwsArgumentError,
      );
    });

    test('throws for malformed redirectUri', () {
      expect(
        () => ConnectPersonaAuth(
          clientId: 'client_test',
          redirectUri: 'not-a-valid-uri',
          environment: ConnectEnvironment.dev,
        ),
        throwsArgumentError,
      );
    });
  });

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
        state: 'test-state',
      );

      expect(uri.scheme, 'https');
      expect(uri.host, 'dev.connectpersona.com');
      expect(uri.path, '/api/v1/oauth/authorize');
      expect(uri.queryParameters['client_id'], 'client_test');
      expect(uri.queryParameters['redirect_uri'], _redirectUri);
      expect(uri.queryParameters['scope'], 'profile.basic');
      expect(uri.queryParameters['response_type'], 'code');
      expect(uri.queryParameters['state'], 'test-state');
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
        state: 's',
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
          'scope': 'admin',
          'state': 'hijacked',
          'role': 'B',
        },
        state: 'real-state',
      );

      expect(uri.queryParameters['client_id'], 'client_test');
      expect(uri.queryParameters['redirect_uri'], _redirectUri);
      expect(uri.queryParameters['response_type'], 'code');
      expect(uri.queryParameters['scope'], 'profile.basic');
      expect(uri.queryParameters['state'], 'real-state');
      expect(uri.queryParameters['role'], 'B');
    });
  });

  group('signIn routing', () {
    test('uses app path when launch succeeds (no web fallback)', () async {
      var webOpened = false;
      final shortAuth = ConnectPersonaAuth(
        clientId: 'client_test',
        redirectUri: _redirectUri,
        environment: ConnectEnvironment.dev,
        signInTimeout: const Duration(milliseconds: 80),
        canLaunchUrlFn: (_) async => true,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async {
          expect(uri.scheme, 'connectpersona');
          expect(uri.queryParameters['role'], 'O');
          expect(uri.queryParameters['state'], isNotEmpty);
          return true;
        },
        waitForAppBackgroundFn: (_) async => true,
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          webOpened = true;
          return _redirectWithCode('nope', state: url.queryParameters['state']);
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

    test('fake launch without background falls back to web', () async {
      var webOpened = false;
      final auth = buildAuth(
        canLaunchUrlFn: (_) async => true,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => true,
        waitForAppBackgroundFn: (_) async => false,
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          webOpened = true;
          return _redirectWithCode(
            'web-fallback',
            state: url.queryParameters['state'],
          );
        },
      );

      final code = await auth.signIn(webQueryParams: {'role': 'O'});
      expect(code, 'web-fallback');
      expect(webOpened, isTrue);
      await auth.dispose();
    });

    test('falls back to SDK web opener when app missing', () async {
      Uri? openedUrl;
      final auth = buildAuth(
        canLaunchUrlFn: (_) async => false,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => false,
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          openedUrl = url;
          expect(scheme, 'https');
          expect(httpsHost, 'dev.parking.lahvplus.com');
          expect(httpsPath, '/check_account');
          return _redirectWithCode(
            'abc123',
            state: url.queryParameters['state'],
          );
        },
      );

      final code = await auth.signIn(
        webQueryParams: {'role': 'O', 'signup': 'false'},
      );

      expect(code, 'abc123');
      expect(openedUrl?.queryParameters['role'], 'O');
      expect(openedUrl?.queryParameters['signup'], 'false');
      expect(openedUrl?.queryParameters['state'], isNotEmpty);
      await auth.dispose();
    });

    test('still attempts launch when canLaunchUrl is false', () async {
      var launchAttempts = 0;
      final auth = buildAuth(
        canLaunchUrlFn: (_) async => false,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async {
          launchAttempts++;
          return true;
        },
        waitForAppBackgroundFn: (_) async => false,
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          return _redirectWithCode(
            'from-web',
            state: url.queryParameters['state'],
          );
        },
      );

      final code = await auth.signIn();
      expect(code, 'from-web');
      expect(launchAttempts, 1);
      await auth.dispose();
    });

    test('uses onOpenWebAuthorize escape hatch when provided', () async {
      final auth = buildAuth(
        canLaunchUrlFn: (_) async => false,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => false,
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          fail('default web opener should not run');
        },
      );

      final code = await auth.signIn(
        webQueryParams: {'role': 'B'},
        onOpenWebAuthorize: (url) async {
          expect(url.queryParameters['role'], 'B');
          expect(url.queryParameters['state'], isNotEmpty);
          return 'host-code';
        },
      );

      expect(code, 'host-code');
      await auth.dispose();
    });

    test('rejects empty code from web callback', () async {
      final auth = buildAuth(
        canLaunchUrlFn: (_) async => false,
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

    test('rejects web redirect with wrong state', () async {
      final auth = buildAuth(
        canLaunchUrlFn: (_) async => false,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => false,
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          return _redirectWithCode('abc', state: 'wrong-state');
        },
      );

      await expectLater(
        auth.signIn(),
        throwsA(
          isA<ConnectAuthException>().having(
            (e) => e.code,
            'code',
            ConnectAuthException.stateMismatch,
          ),
        ),
      );
      await auth.dispose();
    });

    test('throws appNotAvailable when web authorize URL is invalid', () async {
      final auth = buildAuth(
        webAuthorizeBaseUrl: 'not-a-valid-uri',
        canLaunchUrlFn: (_) async => false,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => false,
      );

      await expectLater(
        auth.signIn(),
        throwsA(
          isA<ConnectAuthException>().having(
            (e) => e.code,
            'code',
            ConnectAuthException.appNotAvailable,
          ),
        ),
      );
      await auth.dispose();
    });

    test('throws alreadyInProgress for concurrent signIn calls', () async {
      final auth = buildAuth(
        canLaunchUrlFn: (_) async => true,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return false;
        },
        waitForAppBackgroundFn: (_) async => false,
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return _redirectWithCode(
            'late',
            state: url.queryParameters['state'],
          );
        },
      );

      final first = auth.signIn();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await expectLater(
        auth.signIn(),
        throwsA(
          isA<ConnectAuthException>().having(
            (e) => e.code,
            'code',
            ConnectAuthException.alreadyInProgress,
          ),
        ),
      );

      await first;
      await auth.dispose();
    });

    testWidgets('detects sync background during launch', (tester) async {
      final auth = buildAuth(
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async {
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          return true;
        },
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          fail('web fallback should not run');
        },
      );

      final launched = await auth.openAuthorizeScreen(
        state: 'sync-bg-state',
        webQueryParams: {'role': 'O'},
      );

      expect(launched, isTrue);
      await auth.dispose();
    });

    test('resolves deep link delivered after resume without cancelling', () async {
      final linkController = StreamController<Uri>.broadcast();
      final fakePlatform = FakeAppLinksPlatform(
        uriLinkStream: linkController.stream,
      );
      AppLinksPlatform.instance = fakePlatform;
      String? capturedState;

      final auth = buildAuth(
        appLinks: AppLinks(),
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async {
          capturedState = uri.queryParameters['state'];
          return true;
        },
        waitForAppBackgroundFn: (_) async => true,
        webAuthorizeOpener: (url, scheme, {httpsHost, httpsPath}) async {
          fail('web fallback should not run');
        },
      );

      final signInFuture = auth.signIn();

      await Future<void>.delayed(const Duration(milliseconds: 50));
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );

      await Future<void>.delayed(const Duration(milliseconds: 700));
      linkController.add(
        Uri.parse(_redirectWithCode('delayed-code', state: capturedState)),
      );

      expect(await signInFuture, 'delayed-code');
      await linkController.close();
      await auth.dispose();
    });
  });

  group('parseAuthorizationCode', () {
    test('returns code for matching redirect', () {
      final auth = buildAuth();
      final code = auth.parseAuthorizationCode(
        Uri.parse('$_redirectUri?code=xyz'),
      );
      expect(code, 'xyz');
    });

    test('maps access_denied', () {
      final auth = buildAuth();
      expect(
        () => auth.parseAuthorizationCode(
          Uri.parse('$_redirectUri?error=access_denied'),
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

    test('rejects redirect with wrong path', () {
      final auth = buildAuth();
      expect(
        auth.tryParseAuthorizationCode(
          Uri.parse('https://dev.parking.lahvplus.com/other?code=xyz'),
        ),
        isNull,
      );
    });
  });
}
