import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'connect_auth_exception.dart';

/// Opens the Connect Persona app for OAuth authorization and returns
/// the authorization code from the redirect deep link.
class ConnectPersonaAuth {
  ConnectPersonaAuth({
    required this.clientId,
    required this.redirectUri,
    this.scope = 'profile.basic',
    this.signInTimeout = const Duration(minutes: 5),
    AppLinks? appLinks,
  }) : _appLinks = appLinks ?? AppLinks();

  final String clientId;
  final String redirectUri;
  final String scope;
  final Duration signInTimeout;

  final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  /// Launches the Connect Persona authorize screen without waiting for a code.
  Future<bool> openAuthorizeScreen({VoidCallback? onExternalAppLaunched}) async {
    final appUri = _buildAppUri();

    unawaited(_linkSubscription?.cancel());
    _linkSubscription = null;

    bool launched = false;
    try {
      launched = await launchUrl(appUri, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }

    if (!launched) return false;

    onExternalAppLaunched?.call();
    return true;
  }

  /// Launches Connect Persona and waits for an authorization code redirect.
  Future<String> signIn({
    VoidCallback? onExternalAppLaunched,
    bool listenForRedirect = true,
  }) async {
    final launched = await openAuthorizeScreen(
      onExternalAppLaunched: onExternalAppLaunched,
    );

    if (!launched) {
      throw const ConnectAuthException(
        ConnectAuthException.appNotAvailable,
        'Could not open the Connect Persona app',
      );
    }

    return _waitForAuthorizationCode(listenForRedirect: listenForRedirect);
  }

  Future<String> _waitForAuthorizationCode({
    required bool listenForRedirect,
  }) async {
    final completer = Completer<String>();

    if (listenForRedirect) {
      _linkSubscription = _appLinks.uriLinkStream.listen(
        (uri) => _handleRedirect(uri, completer),
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

    final initial = await _appLinks.getInitialLink();
    if (initial != null) {
      _handleRedirect(initial, completer);
      return;
    }

    final latest = await _appLinks.getLatestLink();
    if (latest != null) {
      _handleRedirect(latest, completer);
    }
  }

  void _handleRedirect(Uri uri, Completer<String> completer) {
    if (completer.isCompleted) return;

    final expected = Uri.parse(redirectUri);
    if (uri.scheme != expected.scheme || uri.host != expected.host) return;

    final params = uri.queryParameters;
    final error = params['error'];
    if (error != null) {
      completer.completeError(
        ConnectAuthException(
          error == 'access_denied'
              ? ConnectAuthException.accessDenied
              : error == 'cancelled' || error == 'user_cancelled'
                  ? ConnectAuthException.cancelled
                  : ConnectAuthException.invalidResponse,
          params['error_description'] ?? error,
        ),
      );
      return;
    }

    final code = params['code'];
    if (code == null || code.isEmpty) {
      completer.completeError(
        const ConnectAuthException(
          ConnectAuthException.invalidResponse,
          'Redirect did not contain an authorization code',
        ),
      );
      return;
    }

    completer.complete(code);
  }

  Future<void> dispose() async {
    unawaited(_linkSubscription?.cancel());
    _linkSubscription = null;
  }
}
