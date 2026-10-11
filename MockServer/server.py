#!/usr/bin/env python3
"""Deterministic localhost fixture. No Twitch extraction, Linux backend, or proxy."""
import argparse, json, re, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit
MEDIA = Path(__file__).parent / 'media'
CAPS = dict(api_version='v1', playback_protocols=['hls'], live=True, vod=True, clips=True, quality_selection=True, downloads=True, authorized_downloads_only=True, ad_handling='none')
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass  # No headers, credentials, or private content in logs.
    def send_json(self, status, value):
        data=json.dumps(value).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def problem(self, status, code, retryable=False): self.send_json(status,dict(error=dict(code=code,message=code.replace('_',' '),retryable=retryable)))
    def job(self): return dict(id='fixture-download',status='ready',progress=1,transferred_bytes=0,total_bytes=(MEDIA/'fixture.mp4').stat().st_size,filename='Twitchy test fixture.mp4',controls=['cancel'])
    def do_GET(self):
        path=urlsplit(self.path).path
        if path=='/__test__/metrics':return self.send_json(200,dict(session_requests=self.server.session_requests,session_creations=self.server.session_creations,session_deletions=self.server.session_deletions))
        if path=='/__test__/playback-quality':return self.send_json(200,dict(quality=self.server.last_requested_quality))
        if path=='/v1/health': return self.send_json(200,dict(status='ok',server_version='mock-1.0.0',api_version='v1'))
        if path=='/v1/capabilities': return self.send_json(200,CAPS)
        if path=='/v1/downloads/fixture-download': return self.send_json(200,self.job())
        filename='fixture.mp4' if path=='/v1/downloads/fixture-download/file' else path.removeprefix('/media/')
        if path.startswith('/media/') or path=='/v1/downloads/fixture-download/file':
            if not re.fullmatch(r'fixture(?:\d+)?\.(mp4|m3u8|ts|png)',filename):return self.problem(404,'not_found')
            file=MEDIA/filename
            if not file.is_file():return self.problem(404,'not_found')
            data=file.read_bytes();self.send_response(200);self.send_header('Content-Type','application/vnd.apple.mpegurl' if file.suffix=='.m3u8' else 'video/mp4' if file.suffix=='.mp4' else 'image/png' if file.suffix=='.png' else 'video/mp2t');self.send_header('Content-Length',str(len(data)));self.send_header('Content-Disposition','attachment; filename="fixture.mp4"');self.end_headers();self.wfile.write(data);return
        self.problem(404,'not_found')
    def do_POST(self):
        try:
            length=int(self.headers.get('Content-Length','0'))
            if length>4096:return self.problem(400,'invalid_request')
            body=json.loads(self.rfile.read(length))
        except (ValueError,TypeError):return self.problem(400,'invalid_request')
        if self.path=='/v1/playback/sessions':
            with self.server.counter_lock:
                self.server.session_requests+=1
                self.server.last_requested_quality=body.get("requested_quality")
                login=body.get('channel_login','')
                attempt=self.server.channel_attempts.get(login,0)+1
                self.server.channel_attempts[login]=attempt
            if login=='fixture-slow':time.sleep(15)
            if login.startswith('fixture-transient') and attempt==1:return self.problem(503,'source_busy',retryable=True)
            if login=='fixture-unavailable':return self.problem(404,'stream_unavailable')
            if body.get('content_type') not in ['live','vod','clip']:return self.problem(400,'invalid_content_type')
            with self.server.counter_lock:
                self.server.session_creations+=1
                session_id=f'fixture-session-{self.server.session_creations}' if self.server.unique_sessions else 'fixture-session'
            return self.send_json(201,dict(session_id=session_id,hls_url=f'http://localhost:{self.server.server_port}/media/fixture.m3u8',qualities=['auto','360p'],title='Local generated test fixture',player_capabilities=['pause','seek','pip'],state='playing',filtering_status='none'))
        if self.path=='/v1/downloads':
            if body.get('authorization_reference')!='fixture-owner':return self.problem(403,'permission_required')
            return self.send_json(202,self.job())
        self.problem(404,'not_found')
    def do_DELETE(self):
        if re.fullmatch(r'/v1/playback/sessions/fixture-session(?:-\d+)?',self.path) or self.path=='/v1/downloads/fixture-download':
            if self.path.startswith('/v1/playback/'):
                with self.server.counter_lock:self.server.session_deletions+=1
            self.send_response(204);self.end_headers()
        else:self.problem(404,'not_found')
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8181);parser.add_argument('--media-dir',type=Path,default=MEDIA);parser.add_argument('--unique-sessions',action='store_true');args=parser.parse_args()
    MEDIA=args.media_dir.resolve()
    print(f'Twitchy MOCK fixture only: http://localhost:{args.port}',flush=True)
    server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    server.counter_lock=threading.Lock();server.session_requests=0;server.channel_attempts={};server.session_creations=0;server.session_deletions=0;server.unique_sessions=args.unique_sessions;server.last_requested_quality=None
    server.serve_forever()
