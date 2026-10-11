# Real server download fixtures

The four `clip-audio-{true,false}.mp4` / `vod-audio-{true,false}.mp4` files are copies of the actual HTTP-download regression output in twitchy-server `.local/audio-regression/container-output/`, produced by the corrected server using container FFmpeg 5.1.9, not client-generated imitations. The server's `internal/server/downloads_test.go` synthesizes six seconds of `testsrc2=size=160x90:rate=25` with optional 440 Hz, stereo 48 kHz AAC, then exercises the clip/VOD routes and their production MPEG-TS → MP4 copy-remux arguments (`frag_keyframe+delay_moov+default_base_moof`). There is no Twitch/user media or signed URL in these files.

Clip and VOD outputs are byte-identical within each audio setting; keep the four route-named outputs to document both server paths.

SHA-256:

- Audio true (clip and VOD): `2e743331c981ac1a5eb9bcaff72d2f9f9808133a478557d5a98de2774dad7fe9`
- Audio false (clip and VOD): `a202244bf0c41e40844236a72d687593fffdcaa9413523bf97820d92799c30f3`

Original timing: movie timescale 1000, video timescale 90000, audio timescale 48000. Video edits are `(80, -1), (0, 7200)`; audio edits are `(58, -1), (0, 0)`, all at media rate 1. These fixture values must not become production constants. Video's positive composition offsets arise from B-frame reordering. Track fragment decode times start at zero and are contiguous.

`fragmented-8s.mp4` remains the older no-edit-list regression. Version-1 edit lists, another movie timescale, finite edits and an AAC-frame trim are test mutations of the real container output; they are explicitly separate from the original server files.
