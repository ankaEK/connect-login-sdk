import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';

import 'connect_auth_exception.dart';

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

  Future<String> signIn() async {
    final appUri = _buildAppUri();

    await _linkSubscription?.cancel();
    final completer = Completer<String>();

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

    bool launched = false;
    try {
      launched = await launchUrl(appUri, mode: LaunchMode.externalApplication);
      // ignore: avoid_print
      print('DEBUG_LAUNCH_RESULT: $launched');
    } catch (e) {
      // ignore: avoid_print
      print('DEBUG_LAUNCH_THREW: $e');
      launched = false;
    }

    if (!launched) {
      await _linkSubscription?.cancel();
      throw const ConnectAuthException(
        ConnectAuthException.appNotAvailable,
        'Could not open the Connect Persona app',
      );
    }
    try {
      return await completer.future.timeout(
        signInTimeout,
        onTimeout: () => throw ConnectAuthException(
          ConnectAuthException.timeout,
          'Timed out waiting for the Connect Persona app redirect',
        ),
      );
    } finally {
      await _linkSubscription?.cancel();
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
    await _linkSubscription?.cancel();
    _linkSubscription = null;
  }
}
