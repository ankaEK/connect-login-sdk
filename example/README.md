# login_with_connect example

Minimal Flutter host for [`login_with_connect`](../) — the same integration
pattern documented in the [root README](../README.md).

## What it demonstrates

- `ConnectPersonaAuth.signIn` with app → web fallback callbacks
- Display of the OAuth authorization code on success
- Sample backend token-exchange `curl` (secret redacted)
- Cold-start recovery via `ConnectPersonaAuth.recoverAuthorizationCode(clientId: …)`
- Android / iOS deep links for `{clientId}://oauth/callback`
- Android package visibility / iOS `LSApplicationQueriesSchemes` for
  `connectpersona://`

## Setup

1. In [`lib/main.dart`](lib/main.dart), set `kClientId` to a Connect Persona
   OAuth client ID for the environment you will use.
2. Optionally set `kScope` (default `profile.basic`).
3. On that portal client, register:

   ```text
   {kClientId}://oauth/callback
   ```

   Use a scheme-safe client id (e.g. `cp-…`, no `_`).
   (`ConnectPersonaAuth.redirectUriForClientId(kClientId)` — already wired in
   this example’s Android and iOS config.)

4. The demo defaults to `ConnectEnvironment.dev`
   (`https://dev.connectpersona.com`). Change `environment:` in
   `_handleSignIn` if you need UAT or prod.

Portal: [developers.connectpersona.com](https://developers.connectpersona.com/)

## Run

```bash
flutter pub get
flutter run
```

Tap **SIGN IN**. On success, copy the code or the sample `curl` and exchange
the code on your **backend** (never ship `client_secret` in the app).

If Android killed the process while Connect was open, the app recovers the
code automatically on the next launch.

## Platform notes

- **Android:** see [`android/app/src/main/AndroidManifest.xml`](android/app/src/main/AndroidManifest.xml)
  for the OAuth intent filter, `connectpersona` queries, and an optional
  Impeller disable (example-only GPU workaround).
- **iOS:** see [`ios/Runner/Info.plist`](ios/Runner/Info.plist) for the URL
  scheme and `LSApplicationQueriesSchemes`.
