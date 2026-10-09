# Performance verification checklist

Use Instruments Time Profiler, Allocations, Network, Energy Log and SwiftUI profiling while scrolling streams and watching actual server media. Local compilation/tests do not establish energy or frame-rate results.

- Confirm image requests and decoded images remain bounded while scrolling; AsyncImage currently relies on system URL loading behavior, not a custom decoded-image cache.
- Observe bounded 300-message chat updates; check high-volume channels and long Unicode/emote fragments.
- Verify debounce cancels obsolete searches and inactive channel sockets stop.
- Check AVPlayer hardware decode on supplied HLS codecs, foreground/background cleanup and audio ownership.
- Measure source preparation polling only while a job is pending; ensure cancellation stops transfer work.
- Check local download progress update cadence, memory under multi-download load and disk-full recovery.
- Verify retained view/controller counts after repeatedly opening/dismissing channel details.
- Test Low Power Mode, Reduce Motion, VoiceOver, Dynamic Type and memory pressure on real hardware.
- Confirm hourly validation causes no frequent background polling and paused/unused sessions expire server-side.
