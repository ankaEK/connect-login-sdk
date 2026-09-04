enum ConnectEnvironment {
  /// https://dev.connectpersona.com
  dev,

  /// https://uat.connectpersona.com
  uat,

  /// https://app.connectpersona.com
  prod;

  String get authHost {
    switch (this) {
      case ConnectEnvironment.dev:
        return 'https://dev.connectpersona.com';
      case ConnectEnvironment.uat:
        return 'https://uat.connectpersona.com';
      case ConnectEnvironment.prod:
        return 'https://app.connectpersona.com';
    }
  }

  Uri get authorizeBaseUri =>
      Uri.parse('$authHost/api/v1/oauth/authorize');

  /// Custom URL scheme registered by the matching Connect Persona app build.
  ///
  /// Hosts must declare these in Android `<queries>` /
  /// iOS `LSApplicationQueriesSchemes` so `canLaunchUrl` can detect the app.
  String get connectAppScheme {
    switch (this) {
      case ConnectEnvironment.dev:
        return 'connectpersona-dev';
      case ConnectEnvironment.uat:
        return 'connectpersona-uat';
      case ConnectEnvironment.prod:
        return 'connectpersona';
    }
  }

  /// Native Connect app authorize URI for this environment.
  Uri get connectAppAuthorizeUri =>
      Uri(scheme: connectAppScheme, host: 'oauth', path: '/authorize');
}
