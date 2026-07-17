# Design decisions

## SDK-owned routing
`ConnectPersonaAuth.signIn` always tries the Connect Persona app first
(`connectpersona://oauth/authorize`). If the app cannot be opened, the SDK
falls back to HTTPS web authorize. Hosts should not catch `app_not_available`
to implement their own routing for the default path.

## Host vs SDK OAuth config
- **Host supplies:** `clientId`, `scope`, and `ConnectEnvironment` (from flavor).
- **SDK owns:** fixed `redirectUri` = `ConnectPersonaAuth.sdkRedirectUri`
  (`loginwithconnect://oauth/callback`). Hosts must register this exact URI
  on their Connect portal client and wire matching deep links.

## Environment vs product params
- **Environment / flavor:** host maps Flutter flavor → `ConnectEnvironment`
  (`dev` / `uat` / `prod`). That selects the Connect auth host and authorize
  base URL. Optional `webAuthorizeBaseUrl` overrides the environment URL.
- **Product / flow:** pass explicit `webQueryParams` on `signIn`
  (e.g. `role`, `signup`). These are never inferred from flavor.

## Web fallback
Default web path uses `flutter_web_auth_2` (system auth session / browser).
Optional `onOpenWebAuthorize` lets a host supply a WebView for HTTPS redirects
that need in-app interception (escape hatch only).

## Deep links
App success returns via the fixed SDK `redirectUri` and `app_links`.
While waiting, redirects with missing/wrong `state` are ignored (stale
callbacks) so they cannot fail the in-progress `signIn` with
`state_mismatch`. Only a callback whose `state` matches the current attempt
completes (or errors like `access_denied` for that attempt).

If Android kills the host while Connect is open, call
`ConnectPersonaAuth.recoverAuthorizationCode()` on startup (see example).
`signIn` persists OAuth `state` so a cold-start deep link can still be verified.
`webQueryParams` are applied to both the native app deep link and the HTTPS
authorize URL.

On resume, only `getLatestLink` is consulted (not `getInitialLink`). Stale
callbacks whose `state` does not match the in-progress sign-in are ignored so
a previous session cannot raise a false `state_mismatch`.

## Reserved OAuth keys
`webQueryParams` cannot override `client_id`, `redirect_uri`, `scope`,
`response_type`, or `state`. Those come from SDK construction / oauth defaults.

## Edge cases
- Empty authorization code → `invalid_response`
- User cancel in web session → `cancelled` when detectable
- App launched but no redirect before `signInTimeout` → `timeout`
- Unrelated deep links while waiting are ignored
- Stale redirect with a different `state` → ignored (wait for current attempt)
- Current redirect missing/`state` mismatch → `state_mismatch`

## Example app
`example/` is a minimal host demo: one Sign In button, status / auth code /
errors. Host sets `kClientId` and `kScope`; redirect is the SDK constant
`loginwithconnect://oauth/callback` (wired on Android and iOS).
