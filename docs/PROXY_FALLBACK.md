# Playback source recovery

Configure sources under **Settings → Sources**. Enabled Twitchy Servers and user-configured Twitch Proxies are tried in the order shown there. The app retains a working fallback until the session ends or the user changes playback.

Server entries use the Source API for health, capabilities, session creation and cleanup. Proxy entries resolve live HLS without server or Twitch credentials. Proxy validation checks the master and one child manifest. Both paths use the native AVPlayer.

Recoverable provider failures exclude the affected source UUID for the current recovery chain. A new playback request or explicit Retry starts again at normal priority. Startup and continuous buffering are bounded by a watchdog.

See [source configuration](SOURCES.md) and [dated proxy measurements](PROXY_RESEARCH.md).
