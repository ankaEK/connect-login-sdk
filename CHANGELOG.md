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
