# Streaming Source API v1

[SERVER_API.json](SERVER_API.json) is the normative OpenAPI 3.1 document. This is a **proposed contract**, not a claim of production server behavior. The Apple client and deterministic local fixture implement its client/test sides. A Go/Docker backend is a separate project.

All wire keys use snake_case; dates use UTC RFC3339/ISO8601 without fractional seconds for v1 client compatibility; identifiers match `[a-zA-Z0-9_-]{1,199}`. New optional fields may be added without changing v1. Missing required fields or incompatible api_version are errors. Clients ignore unknown fields. Responses are JSON except file transfers. Base URL may include a path prefix. Maximum control request size should be bounded. Server responses must not contain secrets in error text.

## Authentication and errors
Use independently issued source bearer credentials in Authorization. Never request, accept as source auth, log or proxy the client's Twitch access/refresh tokens. A source may allow anonymous discovery; playback/download security is server policy. Production requires trusted HTTPS. Credentials must not traverse redirects. Clients refuse redirects for control and file requests.

Errors: `{ "error": { "code": "content_unavailable", "message": "Stream is offline", "retryable": false } }`. Stable codes should include invalid_request, authentication_required, permission_required, unsupported_capability, incompatible_api, content_unavailable, expired_session, invalid_state and rate_limited. Use HTTP 400/401/403/404/409/429/500/503 as described in OpenAPI. Retry-After is integer seconds. Twitchy does not automatically retry mutations: session/download creation could duplicate work. Safe Twitch and source GET requests have bounded backoff; structured source errors remain explicit and recoverable through UI retry.

## Discovery
GET /v1/health returns status (`ok` or `degraded`), server_version, api_version. Twitchy currently requires `ok` and `v1` for a successful health check.

GET /v1/capabilities returns api_version, playback_protocols, live, vod, clips, quality_selection, downloads and authorized_downloads_only. ad_handling is optional informational text; it does not guarantee uninterrupted/ad-free playback. v1 uses HLS, with optional platform-compatible MP4 downloads. Only offer features your implementation actually supports. Health and capabilities must be fast and side-effect free.

## Playback
POST /v1/playback/sessions accepts content_type, requested_quality, and channel_login (live) or content_id (vod/clip). Optional preferences.low_latency is advisory. Validate requested qualities; `auto` is always the automatic mode. Return 201 with session_id, hls_url, qualities, optional expires_at/title/player_capabilities/filtering_status/state. Quality identifiers are opaque strings. A changed quality creates a new session; Twitchy ends the previous one. Do not advertise unavailable qualities.

The HLS URL and all manifest segments must work with AVPlayer without attaching the control API's bearer token. Prefer short-lived, appropriately scoped signed URLs; their signatures must never embed long-lived tokens. Apply ownership checks to session creation and deletion. Session URLs may use a trusted HTTPS media host; clients reject embedded user/password and insecure non-local URLs. Playback URLs have finite expiry or server-enforced idle TTL. Reclaim abandoned sessions even if client cleanup fails.

DELETE /v1/playback/sessions/{sessionId} returns 204 and is idempotent. No response body. Current optional state values: playing, buffering, reconnecting, unavailable, paused_by_server, ad_break, unsupported, server_error. v1 creation only delivers an initial state; dynamic source-state events/status are a future extension. Client observes AVPlayer for ongoing buffer/failure states. Server ad handling stays out of the client.

## Authorized downloads
Enable downloads only when authorized_downloads_only=true and the source can prove content rights. POST /v1/downloads accepts content_type (vod/clip), content_id and authorization_reference. The reference must be independently issued and checked by the server against the authenticated principal, rights, content and expiry; **accepting an arbitrary client statement is not authorization**. Live capture is not in v1. Return 202 with a DownloadJob.

GET /v1/downloads/{downloadId} returns status, progress in [0,1], transferred_bytes, optional total_bytes/error/file_url/filename/controls. State progression: queued → preparing → ready; failed or cancelled may interrupt. The server's `ready`/`completed` means the authorized file is available. The client's transferring/completed state tracks the local copy. Unknown length is represented by omitting total_bytes. A failure includes code/message/retryable. Optional controls in v1 are cancel/retry; pause/resume negotiation is reserved for a later extension.

GET /v1/downloads/{downloadId}/file requires ownership and source auth and streams H.264/AAC MP4 with Content-Length and Content-Disposition. No redirects and no Twitch tokens. Return 409 until ready, 403 for revoked rights, 404 for absent jobs. The client uses this endpoint rather than blindly downloading file_url. Filenames from sources are display labels only: local paths use UUIDs to prevent traversal.

DELETE /v1/downloads/{downloadId} cancels/deletes the job and returns idempotent 204. Enforce principal ownership on every operation. Define TTLs for prepared files. The client polls only active preparation jobs at two-second intervals and stops cancelled work. Local transfer retries start over; HTTP Range/background recovery is future work.

## Backend project handoff
1. Implement these exact models/routes and JSON/error/date encodings in Go, including discovery and independent auth.
2. Provide trusted HTTPS and AVPlayer-compatible HLS sessions with expiry, server-side ownership and cleanup.
3. Advertise only actual capabilities. Keep acquisition/filtering strategies separate from official Twitch account services.
4. Implement authorized MP4 preparation, permission-reference validation and streaming responses if downloads are supported.
5. Add contract tests using the checked-in fixture examples, malformed input, authorization/ownership, expired signatures, interruptions and cleanup.
6. Test the Apple app against the backend on physical devices and review Twitch distribution/advertising requirements before launch.
