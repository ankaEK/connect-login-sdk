# login_with_connect example

Minimal demo for [`login_with_connect`](../).

## Setup

1. In [`lib/main.dart`](lib/main.dart), set `kClientId` to a real Connect
   Persona OAuth client ID for the target environment
   (example defaults to `ConnectEnvironment.dev` →
   `https://dev.connectpersona.com`).
2. Optionally set `kScope` (default `profile.basic`).
3. On that portal client, register the **SDK fixed** redirect URI:

   `loginwithconnect://oauth/callback`

   (`ConnectPersonaAuth.sdkRedirectUri` — already wired in Android/iOS
   deep-link config in this example.)

```bash
flutter pub get
flutter run
```

Tap **SIGN IN**. On success, the authorization code is shown — exchange it on
your backend, not in the app.
