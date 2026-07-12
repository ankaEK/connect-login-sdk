# login_with_connect

Flutter package for signing in with **Connect Persona** using deep-link OAuth.

It launches the Connect Persona app, waits for the redirect, and returns an authorization code your app can exchange on the backend.

## Features

- Launch Connect Persona authorize flow (`connectpersona://oauth/authorize`)
- Listen for the OAuth redirect deep link
- Recover the pending link when the host app resumes
- Typed errors via `ConnectAuthException`

## Getting started

1. Add the dependency:

```yaml
dependencies:
  login_with_connect:
    path: ../login_with_connect # or your git / hosted source
```

2. Register your app’s redirect URI scheme (iOS URL types / Android intent filters) so Connect Persona can return to your app.

3. Configure Connect Persona with matching `client_id` and `redirect_uri`.

## Usage

```dart
import 'package:login_with_connect/login_with_connect.dart';

final auth = ConnectPersonaAuth(
  clientId: 'your-client-id',
  redirectUri: 'yourapp://oauth/callback',
  scope: 'profile.basic',
);

try {
  final code = await auth.signIn(
    onExternalAppLaunched: () {
      // Optional: show “Waiting for Connect Persona…” UI
    },
  );
  // Send `code` to your backend to exchange for tokens.
} on ConnectAuthException catch (e) {
  // e.code: access_denied | cancelled | timeout | app_not_available | invalid_response
} finally {
  await auth.dispose();
}
```

Launch only (without waiting for a code):

```dart
final opened = await auth.openAuthorizeScreen();
```

## Platform setup notes

- **Android / iOS:** deep links must match `redirectUri`.
- The Connect Persona app must be installed for `signIn` to succeed.
- Never exchange the authorization code in the client with a secret; do that on your server.

## Additional information

Report issues to your Connect Persona / SDK maintainers. Call `dispose()` when you are done with an auth instance.
