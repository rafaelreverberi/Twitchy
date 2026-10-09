#!/usr/bin/env python3
"""Deterministic localhost fixture. No Twitch extraction, Linux backend, or proxy."""
import argparse, json, re
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit
MEDIA = Path(__file__).parent / 'media'
CAPS = dict(api_version='v1', playback_protocols=['hls'], live=True, vod=True, clips=True, quality_selection=True, downloads=True, authorized_downloads_only=True, ad_handling='none')
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass  # No headers, credentials, or private content in logs.
    def send_json(self, status, value):
        data=json.dumps(value).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def problem(self, status, code): self.send_json(status,dict(error=dict(code=code,message=code.replace('_',' '),retryable=False)))
    def job(self): return dict(id='fixture-download',status='ready',progress=1,transferred_bytes=0,total_bytes=(MEDIA/'fixture.mp4').stat().st_size,filename='Twitchy test fixture.mp4',controls=['cancel'])
    def do_GET(self):
        path=urlsplit(self.path).path
        if path=='/v1/health': return self.send_json(200,dict(status='ok',server_version='mock-1.0.0',api_version='v1'))
        if path=='/v1/capabilities': return self.send_json(200,CAPS)
        if path=='/v1/downloads/fixture-download': return self.send_json(200,self.job())
        filename='fixture.mp4' if path=='/v1/downloads/fixture-download/file' else path.removeprefix('/media/')
        if path.startswith('/media/') or path=='/v1/downloads/fixture-download/file':
            if not re.fullmatch(r'fixture(?:\d+)?\.(mp4|m3u8|ts)',filename):return self.problem(404,'not_found')
            file=MEDIA/filename
            if not file.is_file():return self.problem(404,'not_found')
            data=file.read_bytes();self.send_response(200);self.send_header('Content-Type','application/vnd.apple.mpegurl' if file.suffix=='.m3u8' else 'video/mp4' if file.suffix=='.mp4' else 'video/mp2t');self.send_header('Content-Length',str(len(data)));self.send_header('Content-Disposition','attachment; filename="fixture.mp4"');self.end_headers();self.wfile.write(data);return
        self.problem(404,'not_found')
    def do_POST(self):
        try:
            length=int(self.headers.get('Content-Length','0'))
            if length>4096:return self.problem(400,'invalid_request')
            body=json.loads(self.rfile.read(length))
        except (ValueError,TypeError):return self.problem(400,'invalid_request')
        if self.path=='/v1/playback/sessions':
            if body.get('content_type') not in ['live','vod','clip']:return self.problem(400,'invalid_content_type')
            return self.send_json(201,dict(session_id='fixture-session',hls_url=f'http://localhost:{self.server.server_port}/media/fixture.m3u8',qualities=['auto','360p'],title='Local generated test fixture',player_capabilities=['pause','seek','pip'],state='playing',filtering_status='none'))
        if self.path=='/v1/downloads':
            if body.get('authorization_reference')!='fixture-owner':return self.problem(403,'permission_required')
            return self.send_json(202,self.job())
        self.problem(404,'not_found')
    def do_DELETE(self):
        if self.path in ['/v1/playback/sessions/fixture-session','/v1/downloads/fixture-download']:
            self.send_response(204);self.end_headers()
        else:self.problem(404,'not_found')
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8181);args=parser.parse_args()
    print(f'Twitchy MOCK fixture only: http://localhost:{args.port}',flush=True)
    ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
