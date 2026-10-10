# Twitch authentication

Sources checked against official documentation on 2026-10-10:
- https://dev.twitch.tv/docs/authentication/register-app/
- https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/
- https://dev.twitch.tv/docs/authentication/validate-tokens/
- https://dev.twitch.tv/docs/authentication/refresh-tokens/
- https://dev.twitch.tv/docs/authentication/scopes/

## Default sign-in: all platforms

Twitchy defaults to public Device Code Flow. The bundled public Client ID is `fvgm8ut01pboy0rvn1f6dkdqxw6rft`; its owner confirmed **Client Type: Public** in the Twitch Developer Console on 2026-10-10. If Twitch prevents changing an existing Confidential registration, create a Public registration and enter that ID under Settings → Advanced → Twitch application settings. Never put a client secret in the app, GitHub repository, or Pages HTML.

Choose **Sign in with Twitch**. On Mac, iPhone, and iPad, Twitchy opens Twitch's activation URL in the default browser, including the activation code supplied by Twitch. Confirm the requested permissions there; Twitchy completes sign-in automatically. Settings shows a Continue on Twitch link and the code as a fallback. On Apple TV, use that URL/code on another device. Cancellation stops polling. Existing browser sessions can be used rather than forcing a fresh credential entry.

The app polls at Twitch's interval, handles authorization_pending and slow_down, and stops on expiry. Access and refresh tokens are stored in the device-only Keychain. Startup, foreground, and hourly validation share one operation, so they cannot consume a single-use refresh token concurrently. A replacement refresh token is saved **before** validating its new access token; an interrupted validation can recover after restart. Offline and application configuration errors preserve credentials. A definite Invalid refresh token response clears the invalid session and asks for renewed consent.

Public Device Flow refresh tokens are single-use and have a 30-day inactivity limit according to the Device Flow documentation. Password changes and revoked permissions can also require another login. An old implicit login cannot be upgraded silently; sign in once using the new default flow to obtain a refresh token.

## Optional legacy browser flow

Settings → Advanced retains the previous implicit browser login for Confidential registrations. It returns no refresh token and therefore cannot provide automatic renewal. The browser uses its shared login session. An owned HTTPS callback is necessary only for this legacy flow:

```text
https://rafaelreverberi.github.io/Twitchy/oauth-callback.html
```

Register that exact URL in Twitch Developer Console → OAuth Redirect URLs, and use the identical value in Advanced → Registered redirect URI. The Pages workflow publishes only the static callback and setup index, without external scripts or analytics. The callback reads Twitch's response fragment, removes it from browser history and passes it to `twitchy://oauth`. Tokens stay in the fragment and are not sent to GitHub in the HTTP request. GitHub receives normal hosting metadata. The callback is a return bridge, not a confidential OAuth server.

Legacy login checks unpredictable per-attempt state and exact app callback scheme/host/path, then validates the access token before storage. A fork must host its own callback and update the registered/default URI. Public registrations cannot use the implicit flow.

## Scopes and lifecycle
Default login requests only `user:read:follows`. Enable Twitch chat adds `user:read:chat` and `user:write:chat` for direct user-token EventSub and Send Chat Message. Subscription checking is a typed API facility, not enabled in UI; it would require opt-in `user:read:subscriptions` and reauthorization. No email scope is requested.

At startup restored tokens call Twitch /validate, matching both client and user identity. While connected a cancellable task validates every 3500 seconds, and foreground activation validates again. Expiry prevents new Helix clients until validation/refresh succeeds. 401, missing scopes, cancellation and network errors have user-visible states. Logout clears Keychain and attempts Twitch revocation; failure to revoke is reported with an official Connections-settings recovery.

System browser acceptance, consent, revocation, Device Flow refresh and real session restoration still require account-level integration testing. Tests use fake credentials only. No authentication information is logged or sent to sources.
