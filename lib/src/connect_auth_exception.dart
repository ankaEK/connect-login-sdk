class ConnectAuthException implements Exception {
  const ConnectAuthException(this.code, this.message);

  final String code;
  final String message;

  static const cancelled = 'cancelled';
  static const accessDenied = 'access_denied';
  static const invalidResponse = 'invalid_response';
  static const timeout = 'timeout';
  static const appNotAvailable = 'app_not_available';
  static const stateMismatch = 'state_mismatch';
  static const alreadyInProgress = 'already_in_progress';

  @override
  String toString() => 'ConnectAuthException($code): $message';
}
