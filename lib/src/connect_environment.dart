/// Connect Persona auth environment (maps from the host Flutter flavor).
///
/// This is **not** a product/role param. Hosts should map:
/// `Flavor.dev → ConnectEnvironment.dev`, etc.
/// Product context (e.g. `role=operator`) belongs in [webQueryParams] on sign-in.
enum ConnectEnvironment {
  /// https://dev.connectpersona.com
  dev,

  /// https://uat.connectpersona.com
  uat,

  /// https://app.connectpersona.com
  prod;

  /// Origin host for this environment (no path).
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

  /// Default HTTPS OAuth authorize endpoint for this environment.
  Uri get authorizeBaseUri =>
      Uri.parse('$authHost/api/v1/oauth/authorize');
}
