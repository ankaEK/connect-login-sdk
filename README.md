# login_with_connect

Flutter package for signing in with **Connect Persona**.

The SDK owns login routing: it tries the Connect Persona app first, then falls
back to a web authorize flow. Your host app supplies `clientId` and `scope`,
maps Flutter flavor → environment, calls `signIn`, and exchanges the returned
authorization code on the backend.

The OAuth **redirect URI is fixed in the SDK**
(`ConnectPersonaAuth.sdkRedirectUri`). Register that exact value on your
Connect portal client.

## Features

- SDK-owned app → web routing
- Fixed SDK redirect URI (`loginwithconnect://oauth/callback`)
- Host-supplied `clientId` and `scope`
- `ConnectEnvironment` for dev / uat / prod auth hosts
- `webQueryParams` for product/flow context (e.g. `role`, `signup`)
- Deep-link redirect listening + resume recovery for the app path
- System web auth via `flutter_web_auth_2` (optional host WebView hook)
- Typed errors via `ConnectAuthException`

## Getting started

1. Add the dependency:

```yaml
dependencies:
  login_with_connect:
    path: ../login_with_connect # or your git / hosted source
```

2. In the Connect developer portal, create (or use) an OAuth client and
   register this **exact** redirect URI:

   `loginwithconnect://oauth/callback`

   (`ConnectPersonaAuth.sdkRedirectUri`)

3. Wire the same deep link in Android / iOS (see `example/` manifests).

4. Map your Flutter flavor to `ConnectEnvironment` (do **not** put `role` in flavor).

## Usage

```dart
import 'package:login_with_connect/login_with_connect.dart';

final auth = ConnectPersonaAuth(
  clientId: 'your-client-id', // from Connect portal
  scope: 'profile.basic',     // from host app
  environment: ConnectEnvironment.dev, // from Flutter flavor
);

try {
  final code = await auth.signIn(
    onExternalAppLaunched: () {
      // Optional: show “Waiting for Connect Persona…” UI
    },
    webQueryParams: {
      'role': 'O',
      'signup': 'false',
    },
  );
  // Send `code` to your backend to exchange for tokens.
} on ConnectAuthException catch (e) {
  // e.code: access_denied | cancelled | timeout | app_not_available | invalid_response
} finally {
  await auth.dispose();
}
```

### Flavor → environment

| Flutter flavor | `ConnectEnvironment` | Auth host |
|----------------|----------------------|-----------|
| dev | `ConnectEnvironment.dev` | `https://dev.connectpersona.com` |
| stg / uat | `ConnectEnvironment.uat` | `https://uat.connectpersona.com` |
| prod | `ConnectEnvironment.prod` | `https://app.connectpersona.com` |

Optional: pass `webAuthorizeBaseUrl` to override the environment-derived
`{host}/api/v1/oauth/authorize` URL.

### Optional host WebView

Only if you need in-app WebView interception instead of the SDK browser:

```dart
final code = await auth.signIn(
  webQueryParams: {'role': 'O'},
  onOpenWebAuthorize: (url) async {
    // Open your WebView with [url], intercept redirect, return code
    return code;
  },
);
```

Launch app only (without waiting for a code):

```dart
final opened = await auth.openAuthorizeScreen(state: '...');
```

## Platform setup notes

- **Android / iOS:** deep links must match `ConnectPersonaAuth.sdkRedirectUri`
  (`loginwithconnect://oauth/callback`).
- Never exchange the authorization code in the client with a secret; do that
  on your server.

## Example

See the [`example/`](example/) app for a minimal demo. Set `kClientId` (and
optionally `kScope`) in `example/lib/main.dart` before running. Register
`loginwithconnect://oauth/callback` on that portal client.

## Additional information

See [DESIGN.md](DESIGN.md) for routing and env vs product-param decisions.
Call `dispose()` when you are done with an auth instance.
