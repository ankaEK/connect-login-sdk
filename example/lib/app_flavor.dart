import 'package:login_with_connect/login_with_connect.dart';

enum AppFlavor {
  dev,
  stg,
  prod;

  static AppFlavor get current {
    const raw = String.fromEnvironment('FLAVOR', defaultValue: 'dev');
    return AppFlavor.values.firstWhere(
      (f) => f.name == raw,
      orElse: () => AppFlavor.dev,
    );
  }

  ConnectEnvironment get connectEnvironment => switch (this) {
    AppFlavor.dev => ConnectEnvironment.dev,
    AppFlavor.stg => ConnectEnvironment.uat,
    AppFlavor.prod => ConnectEnvironment.prod,
  };

  String get clientId => switch (this) {
    AppFlavor.dev => 'e48a3e01-8481-4cad-8dc0-f97f19004dc6',
    AppFlavor.stg => 'e48a3e01-8481-4cad-8dc0-f97f19004dc6',
    AppFlavor.prod => 'e48a3e01-8481-4cad-8dc0-f97f19004dc6',
  };
}
