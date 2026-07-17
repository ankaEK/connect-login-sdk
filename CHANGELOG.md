## 0.3.1

* Fix native `state_mismatch` on resume: ignore stale `getInitialLink` callbacks
  and non-matching prior `state` values; only accept the current sign-in state.

## 0.3.2

* Cold-start recovery: persist OAuth `state` during `signIn`; host can call
  `ConnectPersonaAuth.recoverAuthorizationCode()` after process death.
* Ignore stale redirects with missing/wrong `state` while waiting.
* Example recovers code on startup; disable Impeller on Android example
  (black screen / 0×0 viewport on some GPUs).

## 0.3.0

* Host supplies `clientId` and `scope`; redirect URI is fixed in the SDK
  (`ConnectPersonaAuth.sdkRedirectUri` = `loginwithconnect://oauth/callback`).
* Register that exact redirect on every Connect portal client.

## 0.2.0

* SDK-owned login routing: try Connect Persona app, then HTTPS web fallback.
* Add `ConnectEnvironment` (`dev` / `uat` / `prod`) for flavor → auth host mapping.
* Add `webQueryParams` on `signIn` for product/flow context (e.g. `role`).
* Default web path uses `flutter_web_auth_2`; optional `onOpenWebAuthorize` escape hatch.
* Document design decisions in `DESIGN.md`.

## 0.1.0

* Production-ready package layout: public API exported from barrel file.
* `ConnectPersonaAuth` supports `openAuthorizeScreen`, redirect listening, and resume recovery.
* Removed debug logging.
* Documented usage and exception codes.
* Dropped unused `launchFailed` exception code; map cancel errors to `cancelled`.

## 0.0.1

* Initial SDK phase 1 implementation.
