# login_with_connect example

Minimal demo for [`login_with_connect`](../).

## Setup

1. In [`lib/main.dart`](lib/main.dart), set `kClientId` to a real Connect
   Persona OAuth client ID for the **stg/uat** environment
   (`ConnectEnvironment.uat` → `https://uat.connectpersona.com`).
2. Register `loginwithconnect://oauth/callback` as that client's redirect URI
   in Connect (must match Android/iOS deep-link config).

```bash
flutter pub get
flutter run
```

Tap **SIGN IN**. On success, the authorization code is shown — exchange it on
your backend, not in the app.
