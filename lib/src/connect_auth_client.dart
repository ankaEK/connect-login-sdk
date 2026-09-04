import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'connect_auth_exception.dart';
import 'connect_environment.dart';

void _log(String message) {
  developer.log(message, name: 'ConnectPersonaAuth');
}

File? _cachedPendingOAuthStateFile;
Future<File>? _pendingOAuthStateFileResolve;

Future<File> _pendingOAuthStateFile() {
  final cached = _cachedPendingOAuthStateFile;
  if (cached != null) return Future<File>.value(cached);

  return _pendingOAuthStateFileResolve ??= () async {
    try {
      final dir = await getApplicationSupportDirectory();
      return _cachedPendingOAuthStateFile = File(
        '${dir.path}/login_with_connect_oauth_state',
      );
    } catch (e) {
      _log('path_provider unavailable, falling back to systemTemp: $e');
      return _cachedPendingOAuthStateFile = File(
        '${Directory.systemTemp.path}/login_with_connect_oauth_state',
      );
    }
  }();
}

Future<void> _persistOAuthState(String state) async {
  try {
    final file = await _pendingOAuthStateFile();
    await file.writeAsString(state, flush: true);
  } catch (e) {
    _log('Failed to persist oauth state: $e');
  }
}

void _clearPersistedOAuthStateSync() {
  final cached = _cachedPendingOAuthStateFile;
  if (cached == null) return;
  try {
    if (cached.existsSync()) {
      cached.deleteSync();
    }
  } catch (e) {
    _log('Failed to clear oauth state: $e');
  }
}

Future<void> _clearPersistedOAuthState() async {
  try {
    final file = await _pendingOAuthStateFile();
    if (file.existsSync()) {
      file.deleteSync();
    }
  } catch (e) {
    _log('Failed to clear oauth state: $e');
  }
}

Future<String?> _readPersistedOAuthState() async {
  try {
    final file = await _pendingOAuthStateFile();
    if (!file.existsSync()) return null;
    final value = file.readAsStringSync().trim();
    return value.isEmpty ? null : value;
  } catch (e) {
    _log('Failed to read oauth state: $e');
    return null;
  }
}

class ConnectPersonaAuth {
  ConnectPersonaAuth({
    required this.clientId,
    required this.environment,
    this.scope = 'profile.basic',
    this.webAuthorizeBaseUrl,
    this.connectAppScheme,
    this.signInTimeout = const Duration(minutes: 5),
    this.launchHandoffTimeout = const Duration(milliseconds: 1200),
    AppLinks? appLinks,
    Future<bool> Function(Uri uri, {LaunchMode mode})? launchUrlFn,
    Future<bool> Function(Uri uri)? canLaunchUrlFn,
    Future<bool> Function(Duration timeout)? waitForAppBackgroundFn,
    WebAuthorizeOpener? webAuthorizeOpener,
  }) : redirectUri = _redirectUriOrThrow(clientId),
       _parsedRedirectUri = Uri.parse(_redirectUriOrThrow(clientId)),
       _appLinks = appLinks ?? AppLinks(),
       _launchUrl =
           launchUrlFn ??
           ((uri, {mode = LaunchMode.platformDefault}) =>
               launchUrl(uri, mode: mode)),
       _canLaunchUrl = canLaunchUrlFn ?? canLaunchUrl,
       _waitForAppBackground =
           waitForAppBackgroundFn ?? _defaultWaitForAppBackground,
       _webAuthorizeOpener = webAuthorizeOpener ?? _defaultWebAuthorizeOpener {
    if (scope.isEmpty) {
      throw ArgumentError.value(scope, 'scope', 'must not be empty');
    }
  }

  static const String _redirectHost = 'oauth';
  static const String _redirectPath = '/callback';

  static String _redirectUriOrThrow(String clientId) {
    if (clientId.isEmpty) {
      throw ArgumentError.value(clientId, 'clientId', 'must not be empty');
    }
    return redirectUriForClientId(clientId);
  }

  /// OAuth redirect URI for [clientId]: `{clientId}://oauth/callback`.
  /// Register this exact value on the Connect portal client, and wire the same
  /// scheme/host/path in the host app's Android/iOS deep-link config.
  static String redirectUriForClientId(String clientId) {
    final scheme = clientId.replaceAll('_', '-');
    return '$scheme://$_redirectHost$_redirectPath';
  }

  /// Recovers an authorization code after the host process was killed while
  /// Connect was open (cold start via deep link).
  ///
  ///Call from host `initState` / startup. Returns `null` when there is no
  /// matching pending redirect. Clears the persisted OAuth `state` on success.
  ///
  /// Requires that [signIn] had started earlier (state was persisted).
  static Future<String?> recoverAuthorizationCode({
    required String clientId,
    AppLinks? appLinks,
  }) async {
    final expected = await _readPersistedOAuthState();
    if (expected == null) {
      _log('recoverAuthorizationCode: no persisted state');
      return null;
    }

    final expectedRedirect = Uri.parse(redirectUriForClientId(clientId));
    final links = appLinks ?? AppLinks();
    final candidates = <Uri?>[
      await links.getInitialLink(),
      await links.getLatestLink(),
    ];

    for (final uri in candidates) {
      if (uri == null) continue;
      if (!_uriMatchesRedirect(uri, expectedRedirect)) continue;

      final returnedState = uri.queryParameters['state'];
      if (returnedState != expected) {
        _log(
          'recoverAuthorizationCode: ignore uri (expected=$expected, '
          'got=$returnedState)',
        );
        continue;
      }

      final error = uri.queryParameters['error'];
      if (error != null) {
        _clearPersistedOAuthStateSync();
        throw ConnectAuthException(
          error == 'access_denied'
              ? ConnectAuthException.accessDenied
              : error == 'cancelled' || error == 'user_cancelled'
              ? ConnectAuthException.cancelled
              : ConnectAuthException.invalidResponse,
          uri.queryParameters['error_description'] ?? error,
        );
      }

      final code = uri.queryParameters['code'];
      if (code != null && code.isNotEmpty) {
        _log('recoverAuthorizationCode: recovered code from $uri');
        _clearPersistedOAuthStateSync();
        return code;
      }
    }

    return null;
  }

  static bool _uriMatchesRedirect(Uri uri, Uri expected) {
    if (uri.scheme != expected.scheme || uri.host != expected.host) {
      return false;
    }
    if (expected.path.isNotEmpty && expected.path != '/') {
      return uri.path == expected.path;
    }
    return true;
  }

  /// Test helper to seed / clear persisted OAuth state.
  @visibleForTesting
  static Future<void> debugSetPersistedOAuthState(String? state) async {
    if (state == null || state.isEmpty) {
      await _clearPersistedOAuthState();
    } else {
      await _persistOAuthState(state);
    }
  }

  static const reservedOAuthKeys = {
    'client_id',
    'redirect_uri',
    'response_type',
    'scope',
    'state',
  };

  /// Host-supplied OAuth client ID from the Connect developer portal.
  final String clientId;

  /// OAuth redirect URI derived from [clientId] via [redirectUriForClientId].
  final String redirectUri;

  /// Connect auth environment from the host Flutter flavor.
  final ConnectEnvironment environment;

  /// Host-supplied OAuth scope (space-delimited if multiple).
  final String scope;

  /// Optional full override for the HTTPS authorize base URL.
  /// When set, wins over [environment.authorizeBaseUri].
  final String? webAuthorizeBaseUrl;

  final String? connectAppScheme;

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

  String get resolvedConnectAppScheme {
    final override = connectAppScheme;
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return environment.connectAppScheme;
  }

  Uri get resolvedConnectAppAuthorizeUri => Uri(
    scheme: resolvedConnectAppScheme,
    host: 'oauth',
    path: '/authorize',
  );

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
        final reason =
            'launchUrl failed for ${resolvedConnectAppScheme}://';
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
    await _persistOAuthState(state);

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
      // Do not await path_provider here: after returning from Connect the
      // MethodChannel can stall and leave the host on a blank/loading screen.
      // Persist already warmed [_cachedPendingOAuthStateFile]; clear sync.
      if (_cachedPendingOAuthStateFile != null) {
        _clearPersistedOAuthStateSync();
      } else {
        unawaited(_clearPersistedOAuthState());
      }
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

    // Link may already be available (fast redirect / process just resumed).
    await _consumePendingLink(completer, includeInitialLink: true);
    if (completer.isCompleted) {
      return completer.future;
    }

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

    // One immediate resume-style poll in case we became active with the link.
    unawaited(_handleAppResume(completer));

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

    for (final delayMs in [0, 300, 500, 800, 1200]) {
      if (completer.isCompleted) return;
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
      await _consumePendingLink(completer, includeInitialLink: true);
      if (completer.isCompleted) return;
    }
  }

  Uri _buildAppUri({
    required String state,
    Map<String, String>? webQueryParams,
  }) {
    return _buildAuthorizeUri(
      base: resolvedConnectAppAuthorizeUri,
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

  Future<void> _consumePendingLink(
    Completer<String> completer, {
    bool includeInitialLink = false,
  }) async {
    if (completer.isCompleted) return;

    void apply(Uri? uri) {
      if (uri == null || completer.isCompleted) return;
      try {
        final code = tryParseAuthorizationCode(uri);
        if (code != null) completer.complete(code);
      } on ConnectAuthException catch (e) {
        // Only errors for this attempt's state (e.g. access_denied) fail the wait.
        if (!completer.isCompleted) completer.completeError(e);
      }
    }

    if (includeInitialLink) {
      apply(await _appLinks.getInitialLink());
    }
    if (!completer.isCompleted) {
      apply(await _appLinks.getLatestLink());
    }
  }

  /// Parses a redirect for the in-progress sign-in.
  ///
  /// Returns `null` (ignore) when the URI is unrelated or belongs to a prior
  /// attempt (missing/wrong `state` while [_expectedState] is set). Throws
  /// [ConnectAuthException] only for terminal outcomes of *this* attempt
  /// (matching `state` with `error`, empty code, etc.).
  String? tryParseAuthorizationCode(Uri uri) {
    if (!_redirectUriMatches(uri)) {
      return null;
    }

    final returnedState = uri.queryParameters['state'];
    final expected = _expectedState;

    // While sign-in is active, accept only this attempt's state. Stale or
    // partial callbacks (wrong/missing state) must not fail the session.
    if (expected != null &&
        (returnedState == null ||
            returnedState.isEmpty ||
            returnedState != expected)) {
      _log(
        'Ignoring redirect (expected state=$expected, got=$returnedState, uri=$uri)',
      );
      return null;
    }

    return parseAuthorizationCode(uri);
  }

  String parseAuthorizationCode(Uri uri) {
    if (!_redirectUriMatches(uri)) {
      throw const ConnectAuthException(
        ConnectAuthException.invalidResponse,
        'Redirect URI did not match the expected redirectUri',
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

    final returnedState = params['state'];
    _log(
      'Verifying OAuth state (expected=$_expectedState, got=$returnedState)',
    );
    _verifyState(returnedState);

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

  bool _redirectUriMatches(Uri uri) =>
      _uriMatchesRedirect(uri, _parsedRedirectUri);

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
