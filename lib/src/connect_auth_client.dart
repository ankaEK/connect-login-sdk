import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';

import 'connect_auth_exception.dart';
import 'connect_environment.dart';

/// Opens Connect Persona (app first, then web) and returns an authorization code.
///
/// Hosts typically only map Flutter flavor → [environment], call [signIn],
/// then exchange the returned code on their backend.
class ConnectPersonaAuth {
  ConnectPersonaAuth({
    required this.clientId,
    required this.redirectUri,
    required this.environment,
    this.scope = 'profile.basic',
    this.webAuthorizeBaseUrl,
    this.signInTimeout = const Duration(minutes: 5),
    AppLinks? appLinks,
    Future<bool> Function(Uri uri, {LaunchMode mode})? launchUrlFn,
    WebAuthorizeOpener? webAuthorizeOpener,
  })  : _appLinks = appLinks ?? AppLinks(),
        _launchUrl = launchUrlFn ??
            ((uri, {mode = LaunchMode.platformDefault}) =>
                launchUrl(uri, mode: mode)),
        _webAuthorizeOpener = webAuthorizeOpener ?? _defaultWebAuthorizeOpener;

  /// OAuth reserved keys that [webQueryParams] must not override.
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

  final AppLinks _appLinks;
  final Future<bool> Function(Uri uri, {LaunchMode mode}) _launchUrl;
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

  /// Builds the HTTPS authorize URL for web fallback.
  ///
  /// Merge order: base query → oauth defaults → [webQueryParams]
  /// (reserved oauth keys in [webQueryParams] are ignored).
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

  /// Launches the Connect Persona authorize screen without waiting for a code.
  Future<bool> openAuthorizeScreen({VoidCallback? onExternalAppLaunched}) async {
    final appUri = _buildAppUri();

    unawaited(_linkSubscription?.cancel());
    _linkSubscription = null;

    bool launched = false;
    try {
      launched = await _launchUrl(
        appUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      launched = false;
    }

    if (!launched) return false;

    onExternalAppLaunched?.call();
    return true;
  }

  /// Signs in via Connect Persona app when available, otherwise web authorize.
  ///
  /// [webQueryParams] are merged into the HTTPS web URL only (e.g. role, signup).
  /// They are not applied to the native app deep link.
  ///
  /// [onOpenWebAuthorize] is an optional escape hatch (e.g. host WebView).
  /// When omitted, the SDK opens a system auth session via flutter_web_auth_2.
  Future<String> signIn({
    VoidCallback? onExternalAppLaunched,
    bool listenForRedirect = true,
    Map<String, String>? webQueryParams,
    Uri? webAuthorizeUrl,
    Future<String> Function(Uri url)? onOpenWebAuthorize,
  }) async {
    final launched = await openAuthorizeScreen(
      onExternalAppLaunched: onExternalAppLaunched,
    );

    if (launched) {
      return _waitForAuthorizationCode(listenForRedirect: listenForRedirect);
    }

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
      final result = await _webAuthorizeOpener(
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
        unawaited(_consumePendingLink(completer));
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

  Uri _buildAppUri() {
    return Uri(
      scheme: 'connectpersona',
      host: 'oauth',
      path: '/authorize',
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': scope,
        'response_type': 'code',
      },
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

  /// Like [parseAuthorizationCode], but returns `null` when [uri] is not our
  /// configured redirect (so unrelated deep links can be ignored).
  String? tryParseAuthorizationCode(Uri uri) {
    final expected = Uri.parse(redirectUri);
    if (uri.scheme != expected.scheme || uri.host != expected.host) {
      return null;
    }
    return parseAuthorizationCode(uri);
  }

  /// Parses an OAuth redirect [uri] and returns the authorization code.
  ///
  /// Throws [ConnectAuthException] for OAuth errors / missing code.
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
}

/// Opens a web authorize URL and returns the full redirect URI string.
typedef WebAuthorizeOpener = Future<String> Function(
  Uri url,
  String callbackUrlScheme, {
  String? httpsHost,
  String? httpsPath,
});
