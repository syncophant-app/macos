#!/usr/bin/env python3
"""Disposable loopback WebDAV/S3 protocol fixture; no third-party packages or real credentials."""
import argparse
import base64
import hashlib
import hmac
import json
import re
import threading
import urllib.parse
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
from xml.sax.saxutils import escape

DATE = datetime(2025, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
HTTP_DATE = format_datetime(DATE, usegmt=True)
ISO_DATE = '2025-01-02T03:04:05.000Z'
LOCK = threading.RLock()
FILES = {}
DIRS = {'/dav/'}
MULTIPART = {}
HISTORY = []
CONTROLS = {}
COUNTER = 0


class LoopbackHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # This disposable loopback server must not wait for reverse DNS.
        TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]


def put(path, data):
    global COUNTER
    COUNTER += 1
    FILES[path] = (data, '"' + hashlib.sha256(data).hexdigest() + '-' + str(COUNTER) + '"')


def encode(value):
    return urllib.parse.quote(value, safe='-_.~')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def send(self, status, data=b'', headers=None):
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def body(self):
        count = int(self.headers.get('Content-Length', '0'))
        if count > 128 * 1024 * 1024:
            raise ValueError('fixture request too large')
        return self.rfile.read(count)

    def s3_authenticated(self, body):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qsl(url.query, keep_blank_values=True)
        params = dict(query)
        auth = self.headers.get('Authorization', '')
        if 'X-Amz-Signature' in params:
            signature = params.pop('X-Amz-Signature')
            credential = params.get('X-Amz-Credential', '')
            date = params.get('X-Amz-Date', '')
            signed = params.get('X-Amz-SignedHeaders', '')
            query = [(k, v) for k, v in query if k != 'X-Amz-Signature']
            payload_hash = 'UNSIGNED-PAYLOAD'
            expires = int(params.get('X-Amz-Expires', '0'))
            if not 1 <= expires <= 604800:
                return False
        else:
            match = re.fullmatch(r'AWS4-HMAC-SHA256 Credential=([^,]+), SignedHeaders=([^,]+), Signature=([0-9a-f]{64})', auth)
            if not match:
                return False
            credential, signed, signature = match.groups()
            date = self.headers.get('x-amz-date', '')
            payload_hash = self.headers.get('x-amz-content-sha256', '')
            if payload_hash != hashlib.sha256(body).hexdigest():
                return False
        scope = credential.split('/')
        if len(scope) != 5 or scope[0] != 'fixture-access' or scope[2:] != ['us-east-1', 's3', 'aws4_request']:
            return False
        canonical_query = '&'.join(encode(k) + '=' + encode(v) for k, v in sorted(query, key=lambda pair: (encode(pair[0]), encode(pair[1]))))
        canonical_headers = ''.join(name + ':' + ' '.join(self.headers.get(name, '').split()) + '\n' for name in signed.split(';'))
        canonical = '\n'.join([self.command, url.path, canonical_query, canonical_headers, signed, payload_hash])
        to_sign = '\n'.join(['AWS4-HMAC-SHA256', date, '/'.join(scope[1:]), hashlib.sha256(canonical.encode()).hexdigest()])
        key = ('AWS4' + 'fixture-secret').encode()
        for value in scope[1:]:
            key = hmac.new(key, value.encode(), hashlib.sha256).digest()
        expected = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(signature, expected)

    def dispatch(self):
        raw = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(raw.path)
        query = dict(urllib.parse.parse_qsl(raw.query, keep_blank_values=True))
        body = self.body()
        with LOCK:
            if path == '/__fixture/control':
                params = json.loads(body)
                if params.get('put'):
                    put(params['path'], params['put'].encode())
                if params.get('fault'):
                    CONTROLS[params['path']] = params['fault']
                return self.send(200, b'{}')
            if path == '/__fixture/state':
                return self.send(200, json.dumps({'files': {k: {'size': len(v[0]), 'sha256': hashlib.sha256(v[0]).hexdigest(), 'etag': v[1]} for k, v in FILES.items()}, 'history': HISTORY, 'multipart': len(MULTIPART)}).encode())
            HISTORY.append({'method': self.command, 'path': path, 'ifMatch': self.headers.get('If-Match'), 'ifNoneMatch': self.headers.get('If-None-Match'),
                            'overwrite': self.headers.get('Overwrite'), 'range': self.headers.get('Range'), 'uploadId': query.get('uploadId'), 'partNumber': query.get('partNumber')})
            if path.startswith('/dav/'):
                expected = 'Basic ' + base64.b64encode(b'fixture:test-password').decode()
                if self.headers.get('Authorization') != expected:
                    return self.send(401)
            elif path.startswith('/s3/'):
                if not self.s3_authenticated(body):
                    return self.send(403, b'invalid independent SigV4 validation')
            else:
                return self.send(404)
            fault = CONTROLS.get(path)
            if fault == 'redirect':
                return self.send(307, headers={'Location': self.server.endpoint + '/__fixture/capture'})
            if self.command in ('GET', 'HEAD') and path.startswith('/s3/') and query.get('list-type') == '2':
                return self.s3_list(query)
            if path.startswith('/s3/') and self.command == 'POST' and 'uploads' in query:
                upload_id = str(uuid.uuid4())
                MULTIPART[upload_id] = {'path': path, 'parts': {}}
                return self.send(200, ('<InitiateMultipartUploadResult><UploadId>' + upload_id + '</UploadId></InitiateMultipartUploadResult>').encode())
            if path.startswith('/s3/') and 'uploadId' in query:
                return self.multipart(path, query, body)
            if self.command == 'PROPFIND':
                return self.dav_list(path)
            if self.command == 'MKCOL':
                directory = path.rstrip('/') + '/'
                if directory in DIRS or path in FILES:
                    return self.send(405)
                parent = path.rstrip('/').rsplit('/', 1)[0] + '/'
                if parent not in DIRS:
                    return self.send(409)
                DIRS.add(directory)
                return self.send(201)
            if self.command == 'LOCK':
                if path.rstrip('/') + '/' not in DIRS:
                    return self.send(404)
                if self.headers.get('Depth') != 'infinity':
                    return self.send(400)
                return self.send(200, b'<prop xmlns="DAV:"><lockdiscovery><activelock><lockscope><exclusive/></lockscope><depth>infinity</depth></activelock></lockdiscovery></prop>', {'Lock-Token': '<opaquelocktoken:fixture>'})
            if self.command == 'UNLOCK':
                return self.send(204)
            if self.command == 'MOVE':
                if path not in FILES:
                    return self.send(404)
                destination = urllib.parse.unquote(urllib.parse.urlsplit(self.headers.get('Destination', '')).path)
                if destination in FILES:
                    if self.headers.get('Overwrite') == 'F':
                        return self.send(412)
                if not self.conditions(path):
                    return self.send(412)
                FILES[destination] = FILES.pop(path)
                return self.send(201)
            if self.command == 'PUT':
                if fault == 'reject-put-once':
                    CONTROLS.pop(path)
                    return self.send(503)
                if fault == 'race-put':
                    put(path, b'external-writer')
                    CONTROLS.pop(path)
                if not self.conditions(path):
                    return self.send(412)
                new = path not in FILES
                put(path, body)
                # Mutate a target only after its safety backup has been created.
                if fault == 'change-original-after-backup':
                    put('/s3/bucket/root/original.txt', b'external-writer')
                    CONTROLS.pop(path)
                return self.send(200 if path.startswith('/s3/') else (201 if new else 204), headers={'ETag': FILES[path][1]})
            if self.command in ('GET', 'HEAD'):
                if path not in FILES:
                    return self.send(404)
                if not self.conditions(path):
                    return self.send(412)
                data, etag = FILES[path]
                headers = {'ETag': ('W/' if fault == 'weak-etag' else '') + etag, 'Last-Modified': HTTP_DATE}
                if self.command == 'HEAD':
                    return self.send(200, data, headers)
                range_header = self.headers.get('Range')
                if range_header and fault != 'ignore-range':
                    match = re.fullmatch(r'bytes=(\d+)-(\d+)', range_header)
                    if not match:
                        return self.send(400)
                    start, end = map(int, match.groups())
                    if start >= len(data):
                        return self.send(416)
                    end = min(end, len(data) - 1)
                    headers['Content-Range'] = f'bytes {start}-{end}/{len(data)}'
                    result = self.send(206, data[start:end + 1], headers)
                else:
                    result = self.send(200, data, headers)
                if fault == 'mutate-after-get':
                    put(path, b'x' * len(data))
                return result
            if self.command == 'DELETE':
                if path in FILES:
                    if not self.conditions(path):
                        return self.send(412)
                    del FILES[path]
                    return self.send(204)
                directory = path.rstrip('/') + '/'
                if directory in DIRS:
                    if self.headers.get('If') != '(<opaquelocktoken:fixture>)':
                        return self.send(423)
                    if any(k.startswith(directory) for k in FILES) or any(k != directory and k.startswith(directory) for k in DIRS):
                        # A real DAV DELETE would recurse. The driver must never get here for a nonempty collection.
                        for key in list(FILES):
                            if key.startswith(directory):
                                del FILES[key]
                    DIRS.remove(directory)
                    return self.send(204)
                return self.send(404)
            return self.send(405)

    def conditions(self, path):
        if self.headers.get('If-None-Match') == '*' and path in FILES:
            return False
        expected = self.headers.get('If-Match')
        return expected is None or (path in FILES and FILES[path][1] == expected)

    def dav_list(self, path):
        directory = path.rstrip('/') + '/'
        if path not in FILES and directory not in DIRS:
            return self.send(404)
        rows = [path if path in FILES else directory]
        if self.headers.get('Depth') == '1':
            rows.extend(k for k in FILES if k.startswith(directory) and '/' not in k[len(directory):])
            rows.extend(k for k in DIRS if k != directory and k.startswith(directory) and '/' not in k[len(directory):].rstrip('/'))
        xml = []
        for key in rows:
            href = urllib.parse.quote(key, safe='/')
            if CONTROLS.get(path) == 'escaping-href':
                href = '/outside/secret'
            directory = key in DIRS
            data, etag = FILES.get(key, (b'', ''))
            if CONTROLS.get(key) == 'weak-etag':
                etag = 'W/' + etag
            properties = '<d:resourcetype>' + ('<d:collection/>' if directory else '') + '</d:resourcetype>'
            properties += f'<d:getcontentlength>{len(data)}</d:getcontentlength><d:getlastmodified>{HTTP_DATE}</d:getlastmodified><d:getetag>{escape(etag)}</d:getetag>'
            xml.append('<d:response><d:href>' + escape(href) + '</d:href><d:propstat><d:prop>' + properties + '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')
        return self.send(207, ('<d:multistatus xmlns:d="DAV:">' + ''.join(xml) + '</d:multistatus>').encode())

    def s3_list(self, query):
        prefix = query.get('prefix', '')
        root = '/s3/bucket/'
        keys, directories = [], set()
        for path, (data, etag) in sorted(FILES.items()):
            if not path.startswith(root + prefix):
                continue
            key = path[len(root):]
            suffix = key[len(prefix):]
            if '/' in suffix:
                directories.add(prefix + suffix.split('/')[0] + '/')
            else:
                keys.append(f'<Contents><Key>{escape(key)}</Key><Size>{len(data)}</Size><ETag>{escape(etag)}</ETag><LastModified>{ISO_DATE}</LastModified></Contents>')
        keys.extend('<CommonPrefixes><Prefix>' + escape(key) + '</Prefix></CommonPrefixes>' for key in sorted(directories))
        return self.send(200, ('<ListBucketResult><IsTruncated>false</IsTruncated>' + ''.join(keys) + '</ListBucketResult>').encode())

    def multipart(self, path, query, body):
        upload = MULTIPART.get(query['uploadId'])
        if not upload or upload['path'] != path:
            return self.send(404)
        if self.command == 'DELETE':
            del MULTIPART[query['uploadId']]
            return self.send(204)
        if self.command == 'PUT':
            number = int(query['partNumber'])
            etag = '"' + hashlib.md5(body).hexdigest() + '"'
            upload['parts'][number] = (body, etag)
            return self.send(200, headers={'ETag': etag})
        if self.command == 'POST':
            if CONTROLS.get(path) == 'race-complete':
                put(path, b'external-writer')
                CONTROLS.pop(path)
            if not self.conditions(path):
                return self.send(412)
            if CONTROLS.get(path) == 'multipart-error':
                return self.send(200, b'<Error><Code>InternalError</Code></Error>')
            parts = list(ET.fromstring(body))
            assembled = []
            for index, part in enumerate(parts):
                number = int(part.findtext('PartNumber'))
                data, etag = upload['parts'][number]
                if part.findtext('ETag') != etag or (index != len(parts) - 1 and len(data) < 5 * 1024 * 1024):
                    return self.send(400)
                assembled.append(data)
            put(path, b''.join(assembled))
            del MULTIPART[query['uploadId']]
            return self.send(200, ('<CompleteMultipartUploadResult><ETag>' + escape(FILES[path][1]) + '</ETag></CompleteMultipartUploadResult>').encode())
        return self.send(405)

    def do_GET(self): self.dispatch()
    def do_HEAD(self): self.dispatch()
    def do_PUT(self): self.dispatch()
    def do_POST(self): self.dispatch()
    def do_DELETE(self): self.dispatch()
    def do_PROPFIND(self): self.dispatch()
    def do_MKCOL(self): self.dispatch()
    def do_MOVE(self): self.dispatch()
    def do_LOCK(self): self.dispatch()
    def do_UNLOCK(self): self.dispatch()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--ready-file', required=True)
    args = parser.parse_args()
    server = LoopbackHTTPServer(('127.0.0.1', 0), Handler)
    server.endpoint = f'http://127.0.0.1:{server.server_port}'
    with open(args.ready_file, 'w') as file:
        file.write(server.endpoint)
    server.serve_forever()
