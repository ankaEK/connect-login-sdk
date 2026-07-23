# login_with_connect

Flutter SDK for **Sign in with Connect Persona**.

Add Connect login to your app with a single `signIn()` call. The SDK tries the
Connect Persona app first, then falls back to a secure system browser. Your app
receives an OAuth authorization code; exchange it on your **backend** for tokens
and user profile.

| | |
|---|---|
| **Package** | `login_with_connect` |
| **Platforms** | Android, iOS |
| **Auth style** | OAuth 2.0 authorization code |
| **Redirect URI** | Derived from `clientId`: `{clientId}://oauth/callback` |
| **Portal** | [developers.connectpersona.com](https://developers.connectpersona.com/) |

## Overview

1. Host app creates a Connect OAuth client and registers a redirect URI derived
   from its client ID (`{clientId}://oauth/callback`).
2. Host wires Android / iOS deep links for that URI.
3. Host calls `ConnectPersonaAuth.signIn(...)`.
4. SDK opens Connect (app → web fallback) and returns an authorization `code`.
5. Host sends `code` to its backend; backend exchanges it for tokens (never use
   `client_secret` in the mobile app).

```text
┌─────────────┐     signIn()      ┌──────────────────┐
│  Host app   │ ───────────────►  │ login_with_connect│
└─────────────┘                   └────────┬─────────┘
                                           │
                    ┌──────────────────────┼──────────────────────┐
                    ▼                      ▼                      │
           Connect Persona app    System browser / web auth       │
           (connectpersona://)    (HTTPS authorize)               │
                    │                      │                      │
                    └──────────┬───────────┘                      │
                               ▼                                  │
                    {clientId}://oauth/callback                       │
                               │                                  │
                               ▼                                  │
                         authorization code  ◄────────────────────┘
                               │
                               ▼
                         Host backend → /oauth/token
```

## Requirements

- Flutter **3.32+** / Dart **3.8+**
- A Connect Persona OAuth client from the
  [developer portal](https://developers.connectpersona.com/)
- Android and/or iOS project with deep-link support for your redirect URI

## Installation

### Git (recommended until published on pub.dev)

```yaml
dependencies:
  login_with_connect:
    git:
      url: https://github.com/ankaEK/connect-login-sdk.git
      ref: main # pin to a tag/commit in production
```

### Path (monorepo / local development)

```yaml
dependencies:
  login_with_connect:
    path: ../connect-login-sdk
```

Then:

```bash
flutter pub get
```

## Configure your OAuth client

1. Open the [Connect developer portal](https://developers.connectpersona.com/).
2. Create or select an OAuth client for the target environment
   (`dev` / `uat` / `prod`).
3. Register this **exact** redirect URI (derived from your client ID):

   ```text
   {clientId}://oauth/callback
   ```

   Example: if `clientId` is `cp-6d009906-…`, register
   `cp-6d009906-…://oauth/callback`.

   [clientId] must be a valid URI scheme (letters, digits, `+`, `-`, `.`;
   no `_`). Helper: `ConnectPersonaAuth.redirectUriForClientId(clientId)`.

4. Note your **Client ID**. Keep **Client Secret** on the server only.
5. Enable the scopes your app will request (for example `profile.basic`).

## Platform setup

Deep links must match the redirect URI for your `clientId`. Also declare the
Connect app scheme so Android / iOS can detect and launch it.

### Android

In `android/app/src/main/AndroidManifest.xml`:

1. Add an intent filter on your main activity (use `singleTop` or equivalent so
   redirects resume the same task). Replace `YOUR_CLIENT_ID` with the same
   value you pass as `clientId`:

```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <category android:name="android.intent.category.BROWSABLE"/>
    <data
        android:scheme="YOUR_CLIENT_ID"
        android:host="oauth"
        android:pathPrefix="/callback"/>
</intent-filter>
```

2. Under `<manifest>`, allow querying the Connect app (Android 11+ package
   visibility):

```xml
<queries>
    <intent>
        <action android:name="android.intent.action.VIEW"/>
        <data android:scheme="connectpersona"/>
    </intent>
</queries>
```

See the complete file in
[`example/android/app/src/main/AndroidManifest.xml`](example/android/app/src/main/AndroidManifest.xml).

### iOS

In `ios/Runner/Info.plist`:

1. Register the same redirect scheme:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>CFBundleURLName</key>
    <string>com.example.yourapp.oauth</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>YOUR_CLIENT_ID</string>
    </array>
  </dict>
</array>
```

2. Allow querying the Connect Persona app:

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>connectpersona</string>
</array>
```

See [`example/ios/Runner/Info.plist`](example/ios/Runner/Info.plist).

## Usage

### Sign in

```dart
import 'package:login_with_connect/login_with_connect.dart';

final auth = ConnectPersonaAuth(
  clientId: 'your-client-id', // from Connect portal
  scope: 'profile.basic',     // space-delimited if multiple
  environment: ConnectEnvironment.prod, // map from your Flutter flavor
);

try {
  final code = await auth.signIn(
    onExternalAppLaunched: () {
      // Optional: “Waiting for Connect Persona…”
    },
    onFellBackToWeb: () {
      // Optional: “Using web sign-in…”
    },
    onAppLaunchFailed: (reason) {
      // Optional: diagnostics before web fallback
    },
    webQueryParams: {
      // Product / flow context (not environment)
      'role': 'O',
      'signup': 'false',
    },
  );

  // Send `code` to your backend to exchange for tokens.
} on ConnectAuthException catch (e) {
  // See Error handling
} finally {
  await auth.dispose();
}
```

Always call `dispose()` when you are done with an auth instance.

### Recover after process death (Android)

If Android kills your process while Connect is open, the in-flight `signIn`
`Future` is lost. On cold start, recover the code from the deep link:

```dart
@override
void initState() {
  super.initState();
  unawaited(_recover());
}

Future<void> _recover() async {
  try {
    final code = await ConnectPersonaAuth.recoverAuthorizationCode(
      clientId: 'your-client-id',
    );
    if (code == null) return;
    // Same as a successful signIn — send `code` to your backend.
  } on ConnectAuthException catch (e) {
    // User denied / invalid redirect, etc.
  }
}
```

The SDK persists OAuth `state` during `signIn` so a cold-start redirect can be
verified. See the [`example/`](example/) app.

### Environments

Map your Flutter flavor (or build config) to `ConnectEnvironment`. Do **not**
encode product params such as `role` in the flavor — pass those via
`webQueryParams`.

| Flutter flavor | `ConnectEnvironment` | Auth host |
|----------------|----------------------|-----------|
| `dev` | `ConnectEnvironment.dev` | `https://dev.connectpersona.com` |
| `stg` / `uat` | `ConnectEnvironment.uat` | `https://uat.connectpersona.com` |
| `prod` | `ConnectEnvironment.prod` | `https://app.connectpersona.com` |

Authorize URL (default): `{authHost}/api/v1/oauth/authorize`.

Optional override: pass `webAuthorizeBaseUrl` on `ConnectPersonaAuth` to replace
the environment-derived authorize base URL.

### Error handling

`signIn` and `recoverAuthorizationCode` throw `ConnectAuthException`:

| `e.code` | When |
|----------|------|
| `cancelled` | User cancelled (when detectable) |
| `access_denied` | User / server denied access |
| `timeout` | App opened but no redirect before `signInTimeout` (default 5 minutes) |
| `app_not_available` | Connect app unavailable and web authorize URL invalid |
| `invalid_response` | Missing/empty code or unexpected redirect payload |
| `state_mismatch` | Redirect `state` does not match the current attempt |
| `already_in_progress` | Concurrent `signIn` on the same instance |

Stale deep links with a different `state` while waiting are **ignored** (they do
not fail the current attempt).

### Backend: exchange the authorization code

Exchange the code on your **server** with the client secret. Do not embed the
secret in the Flutter app.

Token endpoint (match the same environment as authorize):

```text
POST {authHost}/api/v1/oauth/token
Content-Type: application/json

{
  "client_id": "<your-client-id>",
  "client_secret": "<server-only-secret>",
  "code": "<authorization-code>"
}
```

| Environment | Token host |
|-------------|------------|
| `dev` | `https://dev.connectpersona.com` |
| `uat` | `https://uat.connectpersona.com` |
| `prod` | `https://app.connectpersona.com` |

Typical success payload includes `access_token`, `refresh_token`, `expires_in`,
and a `user` object. Confirm request/response fields with the Connect API docs
for your account.

Authorization codes are short-lived (on the order of one minute) — exchange
promptly.

## Advanced

### Custom in-app WebView

By default, web fallback uses `flutter_web_auth_2` (system auth session). Only
use a custom WebView if you must intercept HTTPS redirects in-process:

```dart
final code = await auth.signIn(
  onOpenWebAuthorize: (url) async {
    // Open your WebView with [url], intercept redirect, return code
    return code;
  },
);
```

### Launch Connect without waiting for a code

```dart
final opened = await auth.openAuthorizeScreen(state: 'your-csrf-state');
```

Prefer `signIn()` for the full app → web → code flow.

### Reserved query keys

`webQueryParams` cannot override: `client_id`, `redirect_uri`, `scope`,
`response_type`, or `state`. Those are set by the SDK.

## Example

The [`example/`](example/) app is a minimal host integration:

1. Set `kClientId` (and optionally `kScope`) in
   [`example/lib/main.dart`](example/lib/main.dart).
2. Ensure the portal client has redirect `{clientId}://oauth/callback`.
3. Run:

```bash
cd example
flutter pub get
flutter run
```

On success, the demo shows the authorization code and a sample token-exchange
`curl` for backend testing. It also calls `recoverAuthorizationCode(clientId: …)`
on startup for Android process-death recovery.

> **Note:** The example disables Impeller on Android
> (`io.flutter.embedding.android.EnableImpeller` = `false`) to avoid a black
> screen on some GPUs. That is an example-app workaround, not an SDK
> requirement.

## Additional information

- Architecture and edge cases: [DESIGN.md](DESIGN.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Issues / source: [github.com/ankaEK/connect-login-sdk](https://github.com/ankaEK/connect-login-sdk)
