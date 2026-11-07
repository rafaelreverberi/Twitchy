#!/usr/bin/env python3
"""Opt-in, bounded HLS probe. Never prints signed media URLs or playlist bodies."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import urljoin, urlsplit
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--template', required=True, help='Permitted HTTPS URL with one {channel} placeholder')
parser.add_argument('--channel', action='append', required=True, help='At most three currently live channel logins')
parser.add_argument('--rounds', type=int, choices=[1, 2], default=1)
args = parser.parse_args()
if len(args.channel) > 3 or args.template.count('{channel}') != 1:
    parser.error('Use one placeholder, at most three channels and at most two rounds')
for channel in args.channel:
    if not re.fullmatch(r'[a-zA-Z0-9_]{1,25}', channel):
        parser.error('Invalid channel login')

def safe(url):
    parts = urlsplit(url)
    if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.fragment:
        raise ValueError('Unsafe HLS URL')
    return url

with tempfile.TemporaryDirectory(prefix='twitchy-proxy-probe-') as temporary:
    folder = Path(temporary)
    def fetch(url, stage, channel, round_index):
        output = folder / stage
        result = subprocess.run(['curl', '--silent', '--max-time', '12', '--max-filesize', '4000000',
            '--proto', '=https', '--proto-redir', '=https', '--max-redirs', '3', '--location',
            '--output', str(output), '--write-out', '%{json}', safe(url)], capture_output=True, text=True)
        raw = json.loads(result.stdout)
        metrics = {key: raw.get(key) for key in ['http_code', 'time_namelookup', 'time_connect',
            'time_appconnect', 'time_starttransfer', 'time_total', 'size_download', 'ssl_verify_result', 'num_redirects']}
        print(json.dumps(dict(channel=channel, round=round_index, stage=stage, host=urlsplit(url).hostname, **metrics)), flush=True)
        if result.returncode or raw['http_code'] != 200:
            raise ValueError('Request failed; not proof the channel is offline')
        return output.read_bytes(), raw.get('url_effective', url)
    for round_index in range(1, args.rounds + 1):
        for channel in args.channel:
            try:
                body, base = fetch(args.template.replace('{channel}', channel.lower()), 'master', channel, round_index)
                text = body.decode()
                if not text.startswith('#EXTM3U'):
                    raise ValueError('Response is not HLS')
                lines = text.splitlines()
                video = [lines[i+1] for i, line in enumerate(lines[:-1]) if line.startswith('#EXT-X-STREAM-INF:') and 'RESOLUTION=' in line]
                if video:
                    # Lowest advertised video rendition limits traffic, retaining audio/video inspection.
                    body, base = fetch(urljoin(base, video[-1]), 'variant', channel, round_index)
                    text = body.decode()
                if not text.startswith('#EXTM3U'):
                    raise ValueError('Variant is not HLS')
                segments = [line for line in text.splitlines() if line and not line.startswith('#')]
                if not segments:
                    raise ValueError('No media segments')
                init = re.search(r'#EXT-X-MAP:.*URI="([^"]+)"', text)
                prefix = fetch(urljoin(base, init[1]), 'init', channel, round_index)[0] if init else b''
                media, _ = fetch(urljoin(base, segments[-1]), 'segment', channel, round_index)
                sample = folder / 'sample.mp4'
                sample.write_bytes(prefix + media)
                if shutil.which('ffprobe'):
                    result = subprocess.run(['ffprobe', '-v', 'quiet', '-show_entries',
                        'stream=codec_name,codec_type,width,height', '-of', 'json', str(sample)], capture_output=True, text=True)
                    print(json.dumps(dict(channel=channel, round=round_index, codecs=json.loads(result.stdout).get('streams', []))), flush=True)
            except (ValueError, IndexError, UnicodeError):
                print(json.dumps(dict(channel=channel, round=round_index, failure='Request or HLS validation failed')), flush=True)
