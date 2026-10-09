#!/usr/bin/env python3
"""Author the versioned wire contract; no runtime backend is generated."""
import json
from pathlib import Path

def ref(name): return {'$ref': f'#/components/schemas/{name}'}
def obj(props, required=()): return {'type': 'object', 'properties': props, 'required': list(required), 'additionalProperties': True}
def string(**kw): return {'type': 'string', **kw}
def array(items): return {'type':'array','items':items}
def boolean(): return {'type':'boolean'}
def response(name, description): return {'description': description, 'content': {'application/json': {'schema': ref(name)}}}
problem = obj({'error': obj({'code': string(), 'message': string(), 'retryable': boolean(), 'request_id': string()}, ['code','message','retryable'])}, ['error'])
schemas = {
 'Health': obj({'status': string(enum=['ok','degraded']), 'server_version':string(), 'api_version':string(enum=['v1'])}, ['status','server_version','api_version']),
 'Capabilities': obj({'api_version':string(enum=['v1']), 'playback_protocols':array(string(enum=['hls'])), 'live':boolean(), 'vod':boolean(), 'clips':boolean(), 'quality_selection':boolean(), 'downloads':boolean(), 'authorized_downloads_only':boolean(), 'ad_handling':string(description='Informational, no guarantee; e.g. none, detection, pause. No client filtering.')}, ['api_version','playback_protocols','live','vod','clips','quality_selection','downloads','authorized_downloads_only']),
 'PlaybackRequest': obj({'content_type':string(enum=['live','vod','clip']), 'channel_login':string(pattern='^[a-zA-Z0-9_]{1,25}$'), 'content_id':string(minLength=1,maxLength=200), 'requested_quality':string(default='auto'), 'preferences':obj({'low_latency':boolean()})}, ['content_type','requested_quality']),
 'PlaybackSession': obj({'session_id':string(pattern='^[a-zA-Z0-9_-]{1,199}$'), 'hls_url':string(format='uri',description='HTTPS AVPlayer-compatible HLS URL; short-lived bearer signature permitted. No long-lived source or Twitch tokens. Local HTTP only explicitly enabled by client.'), 'qualities':array(string()), 'expires_at':string(format='date-time'), 'title':string(), 'player_capabilities':array(string(enum=['pause','seek','pip'])), 'filtering_status':string(), 'state':string(enum=['playing','buffering','reconnecting','unavailable','paused_by_server','ad_break','unsupported','server_error'])}, ['session_id','hls_url','qualities']),
 'DownloadRequest': obj({'content_type':string(enum=['vod','clip']), 'content_id':string(minLength=1,maxLength=200), 'authorization_reference':string(minLength=1,maxLength=512,description='Opaque server-issued reference proving permission. NOT a Twitch OAuth token. Server MUST check ownership, rights, scope, expiry, and principal; a client assertion is insufficient.')}, ['content_type','content_id','authorization_reference']),
 'DownloadJob': obj({'id':string(pattern='^[a-zA-Z0-9_-]{1,199}$'), 'status':string(enum=['queued','preparing','ready','transferring','paused','completed','failed','cancelled']), 'progress':{'type':'number','minimum':0,'maximum':1}, 'transferred_bytes':{'type':'integer','format':'int64','minimum':0}, 'total_bytes':{'type':'integer','format':'int64','minimum':0}, 'error':ref('ProblemDetail'), 'file_url':string(format='uri',description='Optional informational URL. Client uses authenticated /file endpoint.'), 'filename':string(), 'controls':array(string(enum=['cancel','retry']))}, ['id','status','progress','transferred_bytes']),
 'ProblemDetail':obj({'code':string(), 'message':string(), 'retryable':boolean()}, ['code','message','retryable']), 'Error':problem
}
schemas['PlaybackRequest']['oneOf'] = [{'properties': {'content_type': {'const':'live'}}, 'required':['channel_login']}, {'properties': {'content_type': {'enum':['vod','clip']}}, 'required':['content_id']}]
errors = {str(code):response('Error', description) for code,description in [(400,'Invalid input'),(401,'Source authentication required or invalid'),(403,'Insufficient source rights'),(404,'Content or resource unavailable'),(409,'Invalid resource state'),(429,'Rate limited; Retry-After seconds'),(500,'Source failure'),(503,'Source unavailable')]}
def operation(operation_id, success, status='200', body=None):
 d={'operationId':operation_id,'responses':{status:success,**errors}}
 if body: d['requestBody']={'required':True,'content':{'application/json':{'schema':ref(body)}}}
 return d
id_param=lambda name: [{'in':'path','name':name,'required':True,'schema':string(pattern='^[a-zA-Z0-9_-]{1,199}$')}]
paths={
 '/v1/health':{'get':operation('getHealth',response('Health','Health information'))},
 '/v1/capabilities':{'get':operation('getCapabilities',response('Capabilities','Negotiated v1 capabilities'))},
 '/v1/playback/sessions':{'post':operation('createPlaybackSession',response('PlaybackSession','A created, source-owned playback session'),'201','PlaybackRequest')},
 '/v1/playback/sessions/{sessionId}':{'parameters':id_param('sessionId'),'delete':operation('deletePlaybackSession',{'description':'Session stopped; idempotent including already stopped sessions'},'204')},
 '/v1/downloads':{'post':operation('createAuthorizedDownload',response('DownloadJob','Authorized job accepted'),'202','DownloadRequest')},
 '/v1/downloads/{downloadId}':{'parameters':id_param('downloadId'),'get':operation('getDownload',response('DownloadJob','Job state')),'delete':operation('cancelDownload',{'description':'Job cancelled/deleted; idempotent'},'204')},
 '/v1/downloads/{downloadId}/file':{'parameters':id_param('downloadId'),'get':operation('getDownloadFile',{'description':'MP4 (H.264/AAC) authorized file. Content-Length and Content-Disposition required. No redirects; 409 until ready. Streaming response, never JSON.','headers':{'Content-Length':{'schema':{'type':'integer'}},'Content-Disposition':{'schema':string()}},'content':{'video/mp4':{'schema':{'type':'string','format':'binary'}}}})}
}
spec={'openapi':'3.1.0','info':{'title':'Twitchy Streaming Source API','version':'1.0.0','description':'Proposed independent backend contract. NOT a Twitch API or implemented production backend. Source authentication is independent from Twitch.'},'servers':[{'url':'https://source.example.com'}],'security':[{'SourceBearer':[]}], 'paths':paths,'components':{'securitySchemes':{'SourceBearer':{'type':'http','scheme':'bearer','description':'Source-issued credential ONLY; never Twitch credentials'}},'schemas':schemas}}
for path in ['/v1/health','/v1/capabilities']: spec['paths'][path]['get']['security']=[{}, {'SourceBearer':[]}]
Path('docs/SERVER_API.json').write_text(json.dumps(spec,indent=2)+'\n')
