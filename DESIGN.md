# Design decisions

## SDK-owned routing
`ConnectPersonaAuth.signIn` always tries the Connect Persona app first
(`connectpersona://oauth/authorize`). If the app cannot be opened, the SDK
falls back to HTTPS web authorize. Hosts should not catch `app_not_available`
to implement their own routing for the default path.

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
App success still returns via the host `redirectUri` and `app_links`.
`webQueryParams` are applied only to the HTTPS authorize URL, not the native
app deep link.

## Reserved OAuth keys
`webQueryParams` cannot override `client_id`, `redirect_uri`, or
`response_type`. Those always come from SDK construction / oauth defaults.

## Edge cases
- Empty authorization code → `invalid_response`
- User cancel in web session → `cancelled` when detectable
- App launched but no redirect before `signInTimeout` → `timeout`
- Unrelated deep links while waiting are ignored
