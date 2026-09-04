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

  String get connectAppScheme {
    switch (this) {
      case ConnectEnvironment.dev:
        return 'connectpersona.dev';
      case ConnectEnvironment.uat:
        return 'connectpersona.stg';
      case ConnectEnvironment.prod:
        return 'connectpersona';
    }
  }

  Uri get connectAppAuthorizeUri =>
      Uri(scheme: connectAppScheme, host: 'oauth', path: '/authorize');
}
