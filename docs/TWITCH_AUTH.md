# Twitch authentication

Sources checked against official documentation on 2026-10-09:
- https://dev.twitch.tv/docs/authentication/register-app/
- https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/
- https://dev.twitch.tv/docs/authentication/validate-tokens/
- https://dev.twitch.tv/docs/authentication/scopes/

## Browser flow: iPhone, iPad and Mac
Register your own Twitch developer application for the documented implicit flow. Twitch's ordinary Developer Console registration does not reliably accept custom URI callbacks. **Register an owned HTTPS callback page**, for example `https://auth.your-domain.com/twitchy/callback.html`, and configure that exact URL in Twitchy. Do not register `twitchy://oauth` at Twitch.

Host the supplied `docs/oauth-callback.html` as a static page on a domain you control, with trusted HTTPS. It reads Twitch's response fragment in the browser, clears browser history's fragment and forwards it to `twitchy://oauth`, which ASWebAuthenticationSession intercepts. It makes no network calls and stores no token. Configure hosting with no third-party scripts, analytics or content injection and a restrictive Content-Security-Policy; do not use your streaming source as the callback host. The URL fragment is not sent in HTTP requests, but the page's script sees it, so ownership and integrity of this page are essential. The page is a static return bridge, not a confidential OAuth server.

Copy the public Client ID to Profile → Settings → Browser OAuth Client ID and set Registered redirect URI to the HTTPS page. Never copy a client secret. Login uses response_type=token, unpredictable per-attempt state and exact app callback scheme/host/path checks. No undocumented PKCE or confidential code exchange is implemented. The access token is validated before storage. Implicit tokens have no refresh token; expiry/revocation requires reauthentication. Both browser consent and callback bridge require real registration integration testing. If you do not have an owned HTTPS host, use the supported public Device Flow instead; it needs no callback bridge.

## Device flow: Apple TV or alternative sign-in
Create a separate **public client registration for Device Code Flow**. Twitch documents that public Device Flow clients cannot use the other grant flows. Set its ID in Settings → Public Device Flow Client ID. Apple TV's Sign in uses this ID. On other platforms choose Use device authorization.

Twitchy requests /oauth2/device, displays the user code and activation page, polls no faster than the returned interval, handles authorization_pending/slow_down, and stops on expiry or cancellation. It stores the returned access/refresh pair in Keychain. Refresh uses the public Device Flow registration without a secret and stores the newly rotated, one-use refresh token. An invalid refresh token clears local credentials and requests sign-in.

## Scopes and lifecycle
Default browser login requests only `user:read:follows`. Authorize chat adds `user:read:chat` and `user:write:chat` for direct user-token EventSub and Send Chat Message. Subscription checking is a typed API facility, not enabled in UI; it would require opt-in `user:read:subscriptions` and reauthorization. No email scope is requested.

At startup restored tokens call Twitch /validate, matching both client and user identity. While connected a cancellable task validates every 3500 seconds, and foreground activation validates again. Expiry prevents new Helix clients until validation/refresh succeeds. 401, missing scopes, cancellation and network errors have user-visible states. Logout clears Keychain and attempts Twitch revocation; failure to revoke is reported with an official Connections-settings recovery.

System browser acceptance, consent, revocation, Device Flow refresh and real session restoration still require account-level integration testing. Tests use fake credentials only. No authentication information is logged or sent to sources.
