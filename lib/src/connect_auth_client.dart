import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';

import 'connect_auth_exception.dart';
import 'connect_environment.dart';

void _log(String message) {
  developer.log(message, name: 'ConnectPersonaAuth');
}

class ConnectPersonaAuth {
  ConnectPersonaAuth({
    required this.clientId,
    required this.environment,
    this.scope = 'profile.basic',
    this.webAuthorizeBaseUrl,
    this.signInTimeout = const Duration(minutes: 5),
    this.launchHandoffTimeout = const Duration(milliseconds: 1200),
    AppLinks? appLinks,
    Future<bool> Function(Uri uri, {LaunchMode mode})? launchUrlFn,
    Future<bool> Function(Uri uri)? canLaunchUrlFn,
    Future<bool> Function(Duration timeout)? waitForAppBackgroundFn,
    WebAuthorizeOpener? webAuthorizeOpener,
  }) : redirectUri = sdkRedirectUri,
       _parsedRedirectUri = _parsedSdkRedirectUri,
       _appLinks = appLinks ?? AppLinks(),
       _launchUrl =
           launchUrlFn ??
           ((uri, {mode = LaunchMode.platformDefault}) =>
               launchUrl(uri, mode: mode)),
       _canLaunchUrl = canLaunchUrlFn ?? canLaunchUrl,
       _waitForAppBackground =
           waitForAppBackgroundFn ?? _defaultWaitForAppBackground,
       _webAuthorizeOpener = webAuthorizeOpener ?? _defaultWebAuthorizeOpener {
    if (clientId.isEmpty) {
      throw ArgumentError.value(clientId, 'clientId', 'must not be empty');
    }
    if (scope.isEmpty) {
      throw ArgumentError.value(scope, 'scope', 'must not be empty');
    }
  }

  /// Fixed OAuth redirect URI owned by this SDK.
  ///
  /// Register this exact value on every Connect portal client, and wire the
  /// same scheme/host/path in the host app's Android/iOS deep-link config.
  static const String sdkRedirectUri = 'loginwithconnect://oauth/callback';

  static final Uri _parsedSdkRedirectUri = Uri.parse(sdkRedirectUri);

  static const reservedOAuthKeys = {
    'client_id',
    'redirect_uri',
    'response_type',
    'scope',
    'state',
  };

  /// Host-supplied OAuth client ID from the Connect developer portal.
  final String clientId;

  /// Fixed SDK redirect URI ([sdkRedirectUri]). Not host-configurable.
  final String redirectUri;

  /// Connect auth environment from the host Flutter flavor.
  final ConnectEnvironment environment;

  /// Host-supplied OAuth scope (space-delimited if multiple).
  final String scope;

  /// Optional full override for the HTTPS authorize base URL.
  /// When set, wins over [environment.authorizeBaseUri].
  final String? webAuthorizeBaseUrl;

  final Duration signInTimeout;

  /// How long to wait after launchUrl for the host to background (Connect opened).
  final Duration launchHandoffTimeout;

  final Uri _parsedRedirectUri;
  final AppLinks _appLinks;
  final Future<bool> Function(Uri uri, {LaunchMode mode}) _launchUrl;
  final Future<bool> Function(Uri uri) _canLaunchUrl;
  final Future<bool> Function(Duration timeout) _waitForAppBackground;
  final WebAuthorizeOpener _webAuthorizeOpener;

  StreamSubscription<Uri>? _linkSubscription;
  String? _expectedState;
  bool _signInInProgress = false;

  /// HTTPS authorize base used for web fallback.
  Uri get resolvedWebAuthorizeBase {
    final override = webAuthorizeBaseUrl;
    if (override != null && override.isNotEmpty) {
      return Uri.parse(override);
    }
    return environment.authorizeBaseUri;
  }

  Uri buildWebAuthorizeUri({
    Uri? webAuthorizeUrl,
    Map<String, String>? webQueryParams,
    String? state,
  }) {
    return _buildAuthorizeUri(
      base: webAuthorizeUrl ?? resolvedWebAuthorizeBase,
      state: state,
      webQueryParams: webQueryParams,
    );
  }

  Future<bool> openAuthorizeScreen({
    required String state,
    Map<String, String>? webQueryParams,
    VoidCallback? onExternalAppLaunched,
    void Function(String reason)? onAppLaunchFailed,
  }) async {
    final appUri = _buildAppUri(state: state, webQueryParams: webQueryParams);
    _log('Trying Connect app: $appUri');

    unawaited(_linkSubscription?.cancel());
    _linkSubscription = null;

    final handoffFuture = _waitForAppBackground(launchHandoffTimeout);

    try {
      try {
        final canLaunch = await _canLaunchUrl(appUri);
        _log('canLaunchUrl($appUri) => $canLaunch');
        if (!canLaunch) {
          _log(
            'canLaunchUrl=false; still attempting launchUrl '
            '(Android package visibility can be unreliable)',
          );
        }
      } catch (e) {
        _log('canLaunchUrl threw ($e); still attempting launchUrl');
      }

      bool launched = false;
      try {
        launched = await _launchUrl(
          appUri,
          mode: LaunchMode.externalNonBrowserApplication,
        ).timeout(const Duration(seconds: 5), onTimeout: () => false);
        _log('launchUrl(externalNonBrowserApplication) => $launched');

        if (!launched) {
          launched = await _launchUrl(
            appUri,
            mode: LaunchMode.externalApplication,
          ).timeout(const Duration(seconds: 5), onTimeout: () => false);
          _log('launchUrl(externalApplication) => $launched');
        }
      } catch (e) {
        _log('launchUrl threw: $e');
        launched = false;
      }

      if (!launched) {
        const reason = 'launchUrl failed for connectpersona://';
        _log(reason);
        onAppLaunchFailed?.call(reason);
        return false;
      }

      final handedOff = await handoffFuture;
      _log(
        'app background handoff within ${launchHandoffTimeout.inMilliseconds}ms '
        '=> $handedOff',
      );
      if (!handedOff) {
        final reason =
            'no app background within ${launchHandoffTimeout.inMilliseconds}ms '
            '(Connect did not take foreground)';
        _log(reason);
        onAppLaunchFailed?.call(reason);
        return false;
      }

      _log('Connect app path succeeded');
      onExternalAppLaunched?.call();
      return true;
    } finally {
      unawaited(handoffFuture);
    }
  }

  Future<String> signIn({
    VoidCallback? onExternalAppLaunched,
    void Function(String reason)? onAppLaunchFailed,
    VoidCallback? onFellBackToWeb,
    bool listenForRedirect = true,
    Map<String, String>? webQueryParams,
    Uri? webAuthorizeUrl,
    Future<String> Function(Uri url)? onOpenWebAuthorize,
  }) async {
    if (_signInInProgress) {
      throw const ConnectAuthException(
        ConnectAuthException.alreadyInProgress,
        'A sign-in is already in progress',
      );
    }

    _signInInProgress = true;
    final state = _generateState();
    _expectedState = state;

    try {
      final launched = await openAuthorizeScreen(
        state: state,
        webQueryParams: webQueryParams,
        onExternalAppLaunched: onExternalAppLaunched,
        onAppLaunchFailed: onAppLaunchFailed,
      );

      if (launched) {
        return await _waitForAuthorizationCode(
          listenForRedirect: listenForRedirect,
        );
      }

      _log('Falling back to web authorize');
      onFellBackToWeb?.call();
      return await _signInWithWeb(
        webQueryParams: webQueryParams,
        webAuthorizeUrl: webAuthorizeUrl,
        onOpenWebAuthorize: onOpenWebAuthorize,
        state: state,
      );
    } finally {
      _signInInProgress = false;
      _expectedState = null;
    }
  }

  Future<String> _signInWithWeb({
    required String state,
    Map<String, String>? webQueryParams,
    Uri? webAuthorizeUrl,
    Future<String> Function(Uri url)? onOpenWebAuthorize,
  }) async {
    Uri authorizeBase;
    try {
      authorizeBase = webAuthorizeUrl ?? resolvedWebAuthorizeBase;
      if (!authorizeBase.hasScheme || authorizeBase.host.isEmpty) {
        throw const FormatException('invalid authorize base');
      }
    } catch (e) {
      throw ConnectAuthException(
        ConnectAuthException.appNotAvailable,
        'Connect app unavailable and web authorize URL is invalid: $e',
      );
    }

    final url = buildWebAuthorizeUri(
      webAuthorizeUrl: authorizeBase,
      webQueryParams: webQueryParams,
      state: state,
    );

    try {
      if (onOpenWebAuthorize != null) {
        final code = await onOpenWebAuthorize(url).timeout(
          signInTimeout,
          onTimeout: () => throw const ConnectAuthException(
            ConnectAuthException.timeout,
            'Timed out waiting for the web authorize flow',
          ),
        );
        return _requireCode(code);
      }

      final redirect = _parsedRedirectUri;
      final result =
          await _webAuthorizeOpener(
            url,
            redirect.scheme,
            httpsHost: redirect.scheme == 'https' ? redirect.host : null,
            httpsPath: redirect.scheme == 'https' ? redirect.path : null,
          ).timeout(
            signInTimeout,
            onTimeout: () => throw const ConnectAuthException(
              ConnectAuthException.timeout,
              'Timed out waiting for the web authorize flow',
            ),
          );

      return parseAuthorizationCode(Uri.parse(result));
    } on ConnectAuthException {
      rethrow;
    } on TimeoutException {
      throw const ConnectAuthException(
        ConnectAuthException.timeout,
        'Timed out waiting for the web authorize flow',
      );
    } catch (e) {
      final message = e.toString().toLowerCase();
      if (message.contains('cancel')) {
        throw const ConnectAuthException(
          ConnectAuthException.cancelled,
          'Web authorize was cancelled',
        );
      }
      throw ConnectAuthException(
        ConnectAuthException.invalidResponse,
        'Web authorize failed: $e',
      );
    }
  }

  Future<String> _waitForAuthorizationCode({
    required bool listenForRedirect,
  }) async {
    final completer = Completer<String>();

    if (listenForRedirect) {
      _linkSubscription = _appLinks.uriLinkStream.listen(
        (uri) {
          if (completer.isCompleted) return;
          try {
            final code = tryParseAuthorizationCode(uri);
            if (code != null) completer.complete(code);
          } on ConnectAuthException catch (e) {
            if (!completer.isCompleted) completer.completeError(e);
          }
        },
        onError: (Object err) {
          if (!completer.isCompleted) {
            completer.completeError(
              ConnectAuthException(
                ConnectAuthException.invalidResponse,
                'Redirect listener error: $err',
              ),
            );
          }
        },
      );
    }

    final lifecycleListener = AppLifecycleListener(
      onResume: () {
        unawaited(_handleAppResume(completer));
      },
    );

    try {
      return await completer.future.timeout(
        signInTimeout,
        onTimeout: () => throw const ConnectAuthException(
          ConnectAuthException.timeout,
          'Timed out waiting for the Connect Persona app redirect',
        ),
      );
    } finally {
      lifecycleListener.dispose();
      unawaited(_linkSubscription?.cancel());
      _linkSubscription = null;
    }
  }

  Future<void> _handleAppResume(Completer<String> completer) async {
    if (completer.isCompleted) return;

    for (final delayMs in [300, 500, 800, 1200]) {
      if (completer.isCompleted) return;
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      await _consumePendingLink(completer);
      if (completer.isCompleted) return;
    }
  }

  Uri _buildAppUri({
    required String state,
    Map<String, String>? webQueryParams,
  }) {
    return _buildAuthorizeUri(
      base: Uri.parse('connectpersona://oauth/authorize'),
      state: state,
      webQueryParams: webQueryParams,
    );
  }

  Uri _buildAuthorizeUri({
    required Uri base,
    String? state,
    Map<String, String>? webQueryParams,
  }) {
    final params = <String, String>{
      ...base.queryParameters,
      ..._baseOAuthParams(state: state),
    };

    if (webQueryParams != null) {
      for (final entry in webQueryParams.entries) {
        if (reservedOAuthKeys.contains(entry.key)) continue;
        params[entry.key] = entry.value;
      }
    }

    return base.replace(queryParameters: params);
  }

  Map<String, String> _baseOAuthParams({String? state}) {
    final params = <String, String>{
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': scope,
      'response_type': 'code',
    };
    if (state != null) {
      params['state'] = state;
    }
    return params;
  }

  Future<void> _consumePendingLink(Completer<String> completer) async {
    if (completer.isCompleted) return;

    void apply(Uri? uri) {
      if (uri == null || completer.isCompleted) return;
      try {
        final code = tryParseAuthorizationCode(uri);
        if (code != null) completer.complete(code);
      } on ConnectAuthException catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      }
    }

    apply(await _appLinks.getInitialLink());
    if (!completer.isCompleted) {
      apply(await _appLinks.getLatestLink());
    }
  }

  String? tryParseAuthorizationCode(Uri uri) {
    if (!_redirectUriMatches(uri)) {
      return null;
    }
    return parseAuthorizationCode(uri);
  }

  String parseAuthorizationCode(Uri uri) {
    if (!_redirectUriMatches(uri)) {
      throw const ConnectAuthException(
        ConnectAuthException.invalidResponse,
        'Redirect URI did not match the SDK redirectUri',
      );
    }

    final params = uri.queryParameters;
    final error = params['error'];
    if (error != null) {
      throw ConnectAuthException(
        error == 'access_denied'
            ? ConnectAuthException.accessDenied
            : error == 'cancelled' || error == 'user_cancelled'
            ? ConnectAuthException.cancelled
            : ConnectAuthException.invalidResponse,
        params['error_description'] ?? error,
      );
    }

    _verifyState(params['state']);

    return _requireCode(params['code']);
  }

  String _requireCode(String? code) {
    if (code == null || code.isEmpty) {
      throw const ConnectAuthException(
        ConnectAuthException.invalidResponse,
        'Redirect did not contain an authorization code',
      );
    }
    return code;
  }

  void _verifyState(String? returnedState) {
    final expected = _expectedState;
    if (expected == null) return;
    if (returnedState == null || returnedState != expected) {
      throw const ConnectAuthException(
        ConnectAuthException.stateMismatch,
        'OAuth state did not match',
      );
    }
  }

  bool _redirectUriMatches(Uri uri) {
    final expected = _parsedRedirectUri;
    if (uri.scheme != expected.scheme || uri.host != expected.host) {
      return false;
    }
    if (expected.path.isNotEmpty && expected.path != '/') {
      return uri.path == expected.path;
    }
    return true;
  }

  static String _generateState() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> dispose() async {
    unawaited(_linkSubscription?.cancel());
    _linkSubscription = null;
  }

  static Future<String> _defaultWebAuthorizeOpener(
    Uri url,
    String callbackUrlScheme, {
    String? httpsHost,
    String? httpsPath,
  }) {
    return FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: callbackUrlScheme,
      options: FlutterWebAuth2Options(
        httpsHost: httpsHost,
        httpsPath: httpsPath,
      ),
    );
  }

  /// Returns true if the host app backgrounds within [timeout] (Connect opened).
  static Future<bool> _defaultWaitForAppBackground(Duration timeout) async {
    final completer = Completer<bool>();
    final listener = AppLifecycleListener(
      onInactive: () {
        if (!completer.isCompleted) completer.complete(true);
      },
      onHide: () {
        if (!completer.isCompleted) completer.complete(true);
      },
      onPause: () {
        if (!completer.isCompleted) completer.complete(true);
      },
    );

    try {
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } finally {
      listener.dispose();
    }
  }
}

typedef WebAuthorizeOpener =
    Future<String> Function(
      Uri url,
      String callbackUrlScheme, {
      String? httpsHost,
      String? httpsPath,
    });
