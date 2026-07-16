import 'dart:async';
import 'dart:developer' as developer;

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
    required this.redirectUri,
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
  }) : _appLinks = appLinks ?? AppLinks(),
       _launchUrl =
           launchUrlFn ??
           ((uri, {mode = LaunchMode.platformDefault}) =>
               launchUrl(uri, mode: mode)),
       _canLaunchUrl = canLaunchUrlFn ?? canLaunchUrl,
       _waitForAppBackground =
           waitForAppBackgroundFn ?? _defaultWaitForAppBackground,
       _webAuthorizeOpener = webAuthorizeOpener ?? _defaultWebAuthorizeOpener;

  static const reservedOAuthKeys = {
    'client_id',
    'redirect_uri',
    'response_type',
  };

  final String clientId;
  final String redirectUri;

  /// Connect auth environment from the host Flutter flavor.
  final ConnectEnvironment environment;

  final String scope;

  /// Optional full override for the HTTPS authorize base URL.
  /// When set, wins over [environment.authorizeBaseUri].
  final String? webAuthorizeBaseUrl;

  final Duration signInTimeout;

  /// How long to wait after launchUrl for the host to background (Connect opened).
  final Duration launchHandoffTimeout;

  final AppLinks _appLinks;
  final Future<bool> Function(Uri uri, {LaunchMode mode}) _launchUrl;
  final Future<bool> Function(Uri uri) _canLaunchUrl;
  final Future<bool> Function(Duration timeout) _waitForAppBackground;
  final WebAuthorizeOpener _webAuthorizeOpener;

  StreamSubscription<Uri>? _linkSubscription;

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
  }) {
    final base = webAuthorizeUrl ?? resolvedWebAuthorizeBase;
    final params = <String, String>{
      ...base.queryParameters,
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': scope,
      'response_type': 'code',
    };

    if (webQueryParams != null) {
      for (final entry in webQueryParams.entries) {
        if (reservedOAuthKeys.contains(entry.key)) continue;
        params[entry.key] = entry.value;
      }
    }

    return base.replace(queryParameters: params);
  }

  Future<bool> openAuthorizeScreen({
    VoidCallback? onExternalAppLaunched,
    void Function(String reason)? onAppLaunchFailed,
  }) async {
    final appUri = _buildAppUri();
    _log('Trying Connect app: $appUri');

    unawaited(_linkSubscription?.cancel());
    _linkSubscription = null;

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

    final handedOff = await _waitForAppBackground(launchHandoffTimeout);
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
    final launched = await openAuthorizeScreen(
      onExternalAppLaunched: onExternalAppLaunched,
      onAppLaunchFailed: onAppLaunchFailed,
    );

    if (launched) {
      return _waitForAuthorizationCode(listenForRedirect: listenForRedirect);
    }

    _log('Falling back to web authorize');
    onFellBackToWeb?.call();
    return _signInWithWeb(
      webQueryParams: webQueryParams,
      webAuthorizeUrl: webAuthorizeUrl,
      onOpenWebAuthorize: onOpenWebAuthorize,
    );
  }

  Future<String> _signInWithWeb({
    Map<String, String>? webQueryParams,
    Uri? webAuthorizeUrl,
    Future<String> Function(Uri url)? onOpenWebAuthorize,
  }) async {
    final url = buildWebAuthorizeUri(
      webAuthorizeUrl: webAuthorizeUrl,
      webQueryParams: webQueryParams,
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

      final redirect = Uri.parse(redirectUri);
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

    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (completer.isCompleted) return;

    await _consumePendingLink(completer);
    if (completer.isCompleted) return;

    completer.completeError(
      const ConnectAuthException(
        ConnectAuthException.cancelled,
        'Login cancelled',
      ),
    );
  }

  Uri _buildAppUri() {
    return Uri.parse(
      'connectpersona://oauth/authorize'
      '?client_id=${Uri.encodeComponent(clientId)}'
      '&redirect_uri=${Uri.encodeComponent(redirectUri)}'
      '&scope=${Uri.encodeComponent(scope)}'
      '&response_type=code',
    );
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
    final expected = Uri.parse(redirectUri);
    if (uri.scheme != expected.scheme || uri.host != expected.host) {
      return null;
    }
    return parseAuthorizationCode(uri);
  }

  String parseAuthorizationCode(Uri uri) {
    final expected = Uri.parse(redirectUri);
    if (uri.scheme != expected.scheme || uri.host != expected.host) {
      throw const ConnectAuthException(
        ConnectAuthException.invalidResponse,
        'Redirect URI did not match the configured redirectUri',
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
