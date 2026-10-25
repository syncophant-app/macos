#!/usr/bin/env python3
"""Disposable loopback Dropbox/Graph/Box/Google Drive fixture; no third-party packages or real credentials.

Each service has its own in-memory tree. Only the API subset Syncophant's cloud transports use is modelled,
with the conflict and precondition rules they depend on enforced the way the real services document them.
"""
import argparse
import base64
import hashlib
import json
import re
import threading
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer

ISO = '2025-01-02T03:04:05Z'
LOCK = threading.RLock()
SERVICES = ('dropbox', 'onedrive', 'box', 'googledrive')
ROOT_IDS = {'dropbox': 'dbroot', 'onedrive': 'odroot', 'box': '0', 'googledrive': 'groot'}
FOLDER_MIME = 'application/vnd.google-apps.folder'
NODES = {}
COUNTER = [100]
TOKENS = {s: 'access-' + s for s in SERVICES}
REFRESH = {s: 'refresh-' + s for s in SERVICES}
REFRESHES = {s: 0 for s in SERVICES}
IGNORE = set()
DOWNLOADS = {}
SESSIONS = {}
HISTORY = []


def bump():
    COUNTER[0] += 1
    return COUNTER[0]


def reset():
    NODES.clear()
    for service, rid in ROOT_IDS.items():
        NODES[rid] = {'id': rid, 'service': service, 'name': '', 'parent': None, 'folder': True, 'data': b'', 'rev': bump(), 'trashed': False}


def new_node(service, parent, name, folder, data=b''):
    nid = ('g' if service == 'googledrive' else '') + str(bump())
    NODES[nid] = {'id': nid, 'service': service, 'name': name, 'parent': parent, 'folder': folder, 'data': data, 'rev': bump(), 'trashed': False}
    return NODES[nid]


def kids(nid):
    return [n for n in NODES.values() if n['parent'] == nid and not n['trashed']]


def child(nid, name):
    for n in kids(nid):
        if n['name'] == name:
            return n
    return None


def resolve(service, path):
    node = NODES[ROOT_IDS[service]]
    for part in [p for p in path.split('/') if p]:
        if not node['folder']:
            return None
        node = child(node['id'], part)
        if node is None:
            return None
    return node


def path_of(node):
    parts = []
    while node['parent'] is not None:
        parts.append(node['name'])
        node = NODES[node['parent']]
    return '/' + '/'.join(reversed(parts))


def remove_tree(node):
    for k in kids(node['id']):
        remove_tree(k)
    NODES.pop(node['id'], None)


def ensure_parents(service, path):
    node = NODES[ROOT_IDS[service]]
    for part in [p for p in path.split('/') if p][:-1]:
        nxt = child(node['id'], part)
        node = nxt if nxt else new_node(service, node['id'], part, True)
    return node


class LoopbackHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def send(self, status, data=b'', headers=None):
        if isinstance(data, (dict, list)):
            data = json.dumps(data).encode()
            headers = dict(headers or {}, **{'Content-Type': 'application/json'})
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def content(self, data):
        header = self.headers.get('Range')
        if header:
            match = re.fullmatch(r'bytes=(\d+)-(\d+)', header)
            start, end = int(match.group(1)), min(int(match.group(2)), len(data) - 1)
            return self.send(206, data[start:end + 1], {'Content-Range': f'bytes {start}-{end}/{len(data)}'})
        return self.send(200, data)

    def redirect(self, node):
        token = uuid.uuid4().hex
        DOWNLOADS[token] = (node['id'], node['rev'])
        return self.send(302, b'', {'Location': self.server.endpoint + '/download/' + token})

    def dispatch(self):
        raw = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(raw.path)
        query = dict(urllib.parse.parse_qsl(raw.query, keep_blank_values=True))
        count = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(count)
        with LOCK:
            HISTORY.append({'method': self.command, 'path': path, 'authorized': self.headers.get('Authorization') is not None})
            if path == '/__fixture/control':
                params = json.loads(body)
                if 'expire' in params:
                    TOKENS[params['expire']] = 'revoked-' + uuid.uuid4().hex
                if 'ignore' in params:
                    IGNORE.add(params['ignore'])
                if 'seed' in params:
                    seed = params['seed']
                    parent = resolve(seed['service'], seed['parent'])
                    new_node(seed['service'], parent['id'], seed['name'], False, seed['data'].encode())
                return self.send(200, {})
            if path == '/__fixture/state':
                live = {s: sorted(path_of(n) for n in NODES.values() if n['service'] == s and not n['trashed'] and n['parent'] is not None
                                  and all(not NODES[a]['trashed'] for a in self.ancestors(n))) for s in SERVICES}
                return self.send(200, {'paths': live, 'refreshes': REFRESHES, 'history': HISTORY})
            if path.startswith('/token/'):
                return self.token(path[len('/token/'):], dict(urllib.parse.parse_qsl(body.decode())))
            if path.startswith('/download/'):
                if self.headers.get('Authorization'):
                    return self.send(400, b'bearer token leaked to a pre-authorized URL')
                nid, rev = DOWNLOADS.get(path[len('/download/'):], (None, None))
                node = NODES.get(nid)
                if node is None or node['rev'] != rev:
                    return self.send(404)
                return self.content(node['data'])
            if path.startswith('/graph-upload/'):
                if self.headers.get('Authorization'):
                    return self.send(400, b'bearer token leaked to an upload URL')
                return self.graph_chunk(path[len('/graph-upload/'):], body)
            if path.startswith('/google-upload/'):
                return self.google_finish(path[len('/google-upload/'):], body)
            service = {'dropbox': 'dropbox', 'graph': 'onedrive', 'box': 'box', 'google': 'googledrive'}.get(path.split('/')[1])
            if service is None:
                return self.send(404)
            if self.headers.get('Authorization') != 'Bearer ' + TOKENS[service]:
                return self.send(401, {'error': 'invalid_token'})
            if service == 'dropbox':
                return self.dropbox(path, body)
            if service == 'onedrive':
                return self.graph(raw.path, query, body)
            if service == 'box':
                return self.box(path, query, body)
            return self.google(path, query, body)

    def ancestors(self, node):
        out = []
        while node['parent'] is not None:
            node = NODES[node['parent']]
            out.append(node['id'])
        return out

    def token(self, service, form):
        if form.get('grant_type') != 'refresh_token' or form.get('refresh_token') != REFRESH[service] or not form.get('client_id'):
            return self.send(400, {'error': 'invalid_grant'})
        REFRESHES[service] += 1
        TOKENS[service] = f'access-{service}-{REFRESHES[service]}'
        reply = {'access_token': TOKENS[service], 'expires_in': 3600}
        if service in ('box', 'onedrive'):
            REFRESH[service] = f'refresh-{service}-{REFRESHES[service]}'
            reply['refresh_token'] = REFRESH[service]
        return self.send(200, reply)

    # Dropbox ----------------------------------------------------------------------------------------

    def db_meta(self, n):
        if n['folder']:
            return {'.tag': 'folder', 'name': n['name'], 'path_display': path_of(n), 'id': 'id:' + n['id']}
        return {'.tag': 'file', 'name': n['name'], 'path_display': path_of(n), 'id': 'id:' + n['id'], 'rev': format(n['rev'], '09x'),
                'size': len(n['data']), 'server_modified': ISO}

    def db_error(self, summary):
        return self.send(409, {'error_summary': summary})

    def dropbox(self, path, body):
        if path.startswith('/dropbox/content/2/'):
            arg = json.loads(self.headers.get('Dropbox-API-Arg', '{}'))
            return self.dropbox_content(path[len('/dropbox/content/2/'):], arg, body)
        op, args = path[len('/dropbox/api/2/'):], json.loads(body or b'null')
        ignore = 'dropbox' in IGNORE
        if op == 'users/get_current_account':
            return self.send(200, {'email': 'fixture@dropbox.test'})
        if op == 'files/get_metadata':
            n = resolve('dropbox', args['path'])
            return self.send(200, self.db_meta(n)) if n else self.db_error('path/not_found/')
        if op == 'files/list_folder':
            n = resolve('dropbox', args['path'])
            if n is None:
                return self.db_error('path/not_found/')
            if not n['folder']:
                return self.db_error('path/not_folder/')
            return self.send(200, {'entries': [self.db_meta(k) for k in kids(n['id'])], 'has_more': False, 'cursor': 'c'})
        if op == 'files/create_folder_v2':
            if resolve('dropbox', args['path']):
                return self.db_error('path/conflict/folder/')
            parent = ensure_parents('dropbox', args['path'])
            return self.send(200, {'metadata': self.db_meta(new_node('dropbox', parent['id'], args['path'].split('/')[-1], True))})
        if op == 'files/move_v2':
            src, dst = resolve('dropbox', args['from_path']), resolve('dropbox', args['to_path'])
            if src is None:
                return self.db_error('from_lookup/not_found/')
            if dst is not None:
                if not ignore:
                    return self.db_error('to/conflict/file/')
                remove_tree(dst)
            parent = ensure_parents('dropbox', args['to_path'])
            src.update(parent=parent['id'], name=args['to_path'].split('/')[-1])
            return self.send(200, {'metadata': self.db_meta(src)})
        if op == 'files/delete_v2':
            n = resolve('dropbox', args['path'])
            if n is None:
                return self.db_error('path_lookup/not_found/')
            if 'parent_rev' in args and (n['folder'] or format(n['rev'], '09x') != args['parent_rev']):
                return self.db_error('path_write/conflict/file/')
            meta = self.db_meta(n)
            remove_tree(n)
            return self.send(200, {'metadata': meta})
        return self.send(400, b'unsupported dropbox endpoint ' + op.encode())

    def dropbox_content(self, op, arg, body):
        ignore = 'dropbox' in IGNORE
        if op == 'files/download':
            rev = arg['path'][4:] if arg['path'].startswith('rev:') else None
            n = next((x for x in NODES.values() if x['service'] == 'dropbox' and not x['folder'] and format(x['rev'], '09x') == rev), None)
            if n is None:
                return self.db_error('path/not_found/')
            return self.content(n['data'])
        if op == 'files/upload':
            n, mode = resolve('dropbox', arg['path']), arg['mode']
            if not ignore:
                if mode == 'add' and n is not None:
                    return self.db_error('path/conflict/file/')
                if isinstance(mode, dict) and (n is None or n['folder'] or format(n['rev'], '09x') != mode['update']):
                    return self.db_error('path/conflict/file/')
            if n is None:
                n = new_node('dropbox', ensure_parents('dropbox', arg['path'])['id'], arg['path'].split('/')[-1], False, body)
            else:
                n.update(data=body, rev=bump(), folder=False)
            return self.send(200, self.db_meta(n))
        return self.send(400, b'unsupported dropbox content endpoint ' + op.encode())

    # Microsoft Graph --------------------------------------------------------------------------------

    def od_item(self, n):
        out = {'id': n['id'], 'name': n['name'] or 'root', 'eTag': '"{%s},%d"' % (n['id'], n['rev']), 'lastModifiedDateTime': ISO}
        if n['folder']:
            out.update(size=0, folder={'childCount': len(kids(n['id']))})
        else:
            out.update(size=len(n['data']), file={})
        return out

    def od_error(self, status, code):
        return self.send(status, {'error': {'code': code}})

    def od_target(self, raw):
        rest = raw[len('/graph/v1.0/me/drive'):]
        if rest.startswith('/root:'):
            inner = rest[len('/root:'):]
            end = inner.index(':')
            return urllib.parse.unquote(inner[:end]), inner[end + 1:]
        return '/', rest[len('/root'):]

    def graph(self, raw, query, body):
        if raw.rstrip('/') == '/graph/v1.0/me':
            return self.send(200, {'mail': 'fixture@onedrive.test', 'userPrincipalName': 'fixture@onedrive.test'})
        ipath, action = self.od_target(raw)
        n = resolve('onedrive', ipath)
        match = self.headers.get('If-Match')
        ignore = 'onedrive' in IGNORE
        stale = match is not None and not ignore and (n is None or self.od_item(n)['eTag'] != match)
        if action == '' and self.command == 'GET':
            return self.send(200, self.od_item(n)) if n else self.od_error(404, 'itemNotFound')
        if action == '/children' and self.command == 'GET':
            if n is None:
                return self.od_error(404, 'itemNotFound')
            return self.send(200, {'value': [self.od_item(k) for k in kids(n['id'])]})
        if action == '/children' and self.command == 'POST':
            if n is None:
                return self.od_error(404, 'itemNotFound')
            args = json.loads(body)
            if child(n['id'], args['name']):
                return self.od_error(409, 'nameAlreadyExists')
            return self.send(201, self.od_item(new_node('onedrive', n['id'], args['name'], True)))
        if action == '/content' and self.command == 'GET':
            if n is None or n['folder']:
                return self.od_error(404, 'itemNotFound')
            return self.redirect(n)
        if action == '/content' and self.command == 'PUT':
            if stale:
                return self.od_error(412, 'preconditionFailed')
            if n is not None and query.get('@microsoft.graph.conflictBehavior') == 'fail' and not ignore:
                return self.od_error(409, 'nameAlreadyExists')
            return self.od_write(ipath, n, body)
        if action == '/createUploadSession' and self.command == 'POST':
            if stale:
                return self.od_error(412, 'preconditionFailed')
            behavior = json.loads(body)['item']['@microsoft.graph.conflictBehavior']
            if n is not None and behavior == 'fail' and not ignore:
                return self.od_error(409, 'nameAlreadyExists')
            sid = uuid.uuid4().hex
            SESSIONS[sid] = {'path': ipath, 'behavior': behavior, 'data': b''}
            return self.send(200, {'uploadUrl': self.server.endpoint + '/graph-upload/' + sid})
        if action == '' and self.command == 'PATCH':
            if n is None:
                return self.od_error(404, 'itemNotFound')
            if stale:
                return self.od_error(412, 'preconditionFailed')
            args = json.loads(body)
            parent = resolve('onedrive', args['parentReference']['path'][len('/drive/root:'):] or '/')
            if parent is None:
                return self.od_error(404, 'itemNotFound')
            other = child(parent['id'], args['name'])
            if other is not None and other is not n:
                if not ignore:
                    return self.od_error(409, 'nameAlreadyExists')
                remove_tree(other)
            n.update(parent=parent['id'], name=args['name'], rev=bump())
            return self.send(200, self.od_item(n))
        if action == '' and self.command == 'DELETE':
            if n is None:
                return self.od_error(404, 'itemNotFound')
            if stale:
                return self.od_error(412, 'preconditionFailed')
            remove_tree(n)
            return self.send(204)
        return self.send(400, b'unsupported graph request')

    def od_write(self, ipath, n, data):
        if n is None:
            n = new_node('onedrive', ensure_parents('onedrive', ipath)['id'], ipath.split('/')[-1], False, data)
            return self.send(201, self.od_item(n))
        n.update(data=data, rev=bump())
        return self.send(200, self.od_item(n))

    def graph_chunk(self, sid, body):
        session = SESSIONS.get(sid)
        match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', self.headers.get('Content-Range', ''))
        if session is None or match is None or int(match.group(1)) != len(session['data']) or int(match.group(2)) - int(match.group(1)) + 1 != len(body):
            return self.send(400)
        if len(body) % 327680 and int(match.group(2)) + 1 != int(match.group(3)):
            return self.send(400, b'chunk is not a multiple of 320 KiB')
        session['data'] += body
        if len(session['data']) < int(match.group(3)):
            return self.send(202, {'nextExpectedRanges': [f"{len(session['data'])}-"]})
        del SESSIONS[sid]
        n = resolve('onedrive', session['path'])
        if n is not None and session['behavior'] == 'fail' and 'onedrive' not in IGNORE:
            return self.od_error(409, 'nameAlreadyExists')
        return self.od_write(session['path'], n, session['data'])

    # Box --------------------------------------------------------------------------------------------

    def box_item(self, n):
        out = {'type': 'folder' if n['folder'] else 'file', 'id': n['id'], 'name': n['name'] or 'All Files', 'modified_at': ISO,
               'etag': None if n['parent'] is None else str(n['rev']), 'parent': None if n['parent'] is None else {'id': n['parent']},
               'size': 0 if n['folder'] else len(n['data'])}
        return out

    def box_error(self, status, code):
        return self.send(status, {'type': 'error', 'status': status, 'code': code})

    def box_lookup(self, kind, nid):
        n = NODES.get(nid)
        if n is None or n['service'] != 'box' or n['folder'] != (kind == 'folders'):
            return None
        return n

    def box(self, path, query, body):
        ignore = 'box' in IGNORE
        if path.startswith('/box/upload/api/2.0/'):
            return self.box_upload(path[len('/box/upload/api/2.0/'):], body)
        rest = path[len('/box/api/2.0/'):].split('/')
        if rest == ['users', 'me']:
            return self.send(200, {'login': 'fixture@box.test'})
        if rest == ['folders'] and self.command == 'POST':
            args = json.loads(body)
            parent = self.box_lookup('folders', args['parent']['id'])
            if parent is None:
                return self.box_error(404, 'not_found')
            if child(parent['id'], args['name']):
                return self.box_error(409, 'item_name_in_use')
            return self.send(201, self.box_item(new_node('box', parent['id'], args['name'], True)))
        kind, nid = rest[0], rest[1]
        n = self.box_lookup(kind, nid)
        if n is None:
            return self.box_error(404, 'not_found')
        match = self.headers.get('If-Match')
        stale = match is not None and not ignore and self.box_item(n)['etag'] != match
        if len(rest) == 3 and rest[2] == 'items':
            return self.send(200, {'entries': [self.box_item(k) for k in kids(n['id'])], 'next_marker': ''})
        if len(rest) == 3 and rest[2] == 'content':
            return self.redirect(n)
        if self.command == 'GET':
            return self.send(200, self.box_item(n))
        if self.command == 'PUT':
            if stale:
                return self.box_error(412, 'precondition_failed')
            args = json.loads(body)
            parent = self.box_lookup('folders', args.get('parent', {}).get('id', n['parent']))
            if parent is None:
                return self.box_error(404, 'not_found')
            other = child(parent['id'], args['name'])
            if other is not None and other is not n:
                if not ignore:
                    return self.box_error(409, 'item_name_in_use')
                remove_tree(other)
            n.update(parent=parent['id'], name=args['name'], rev=bump())
            return self.send(200, self.box_item(n))
        if self.command == 'DELETE':
            if stale:
                return self.box_error(412, 'precondition_failed')
            if kind == 'folders' and query.get('recursive') != 'true' and kids(n['id']):
                return self.box_error(400, 'folder_not_empty')
            remove_tree(n)
            return self.send(204)
        return self.send(400, b'unsupported box request')

    def box_multipart(self, body):
        boundary = re.search(r'boundary=(\S+)', self.headers.get('Content-Type', '')).group(1).encode()
        parts = {}
        for chunk in body.split(b'--' + boundary)[1:-1]:
            head, _, data = chunk[2:].partition(b'\r\n\r\n')
            name = re.search(rb'name="([^"]+)"', head).group(1).decode()
            parts[name] = data[:-2]
        return json.loads(parts['attributes']), parts['file']

    def box_commit(self, name, parent_id, existing_id, data):
        ignore = 'box' in IGNORE
        if existing_id is None:
            other = child(parent_id, name)
            if other is not None:
                if not ignore:
                    return self.box_error(409, 'item_name_in_use')
                other.update(data=data, rev=bump())
                return self.send(201, {'entries': [self.box_item(other)]})
            return self.send(201, {'entries': [self.box_item(new_node('box', parent_id, name, False, data))]})
        n = self.box_lookup('files', existing_id)
        if n is None:
            return self.box_error(404, 'not_found')
        match = self.headers.get('If-Match')
        if match is not None and not ignore and str(n['rev']) != match:
            return self.box_error(412, 'precondition_failed')
        n.update(data=data, rev=bump())
        return self.send(201, {'entries': [self.box_item(n)]})

    def box_upload(self, op, body):
        rest = op.split('/')
        if rest == ['files', 'content']:
            attributes, data = self.box_multipart(body)
            if self.box_lookup('folders', attributes['parent']['id']) is None:
                return self.box_error(404, 'not_found')
            return self.box_commit(attributes['name'], attributes['parent']['id'], None, data)
        if len(rest) == 3 and rest[0] == 'files' and rest[2] == 'content':
            attributes, data = self.box_multipart(body)
            return self.box_commit(attributes['name'], None, rest[1], data)
        if rest[-1] == 'upload_sessions' and self.command == 'POST':
            args = json.loads(body)
            existing = rest[1] if len(rest) == 3 else None
            if existing is None:
                if child(args['folder_id'], args['file_name']) and 'box' not in IGNORE:
                    return self.box_error(409, 'item_name_in_use')
            else:
                n = self.box_lookup('files', existing)
                match = self.headers.get('If-Match')
                if n is None:
                    return self.box_error(404, 'not_found')
                if match is not None and str(n['rev']) != match and 'box' not in IGNORE:
                    return self.box_error(412, 'precondition_failed')
            sid = uuid.uuid4().hex
            part = 8 * 1024 * 1024
            SESSIONS[sid] = {'name': args.get('file_name') or NODES[existing]['name'], 'parent': args.get('folder_id'), 'existing': existing,
                             'size': args['file_size'], 'parts': {}}
            return self.send(201, {'id': sid, 'part_size': part, 'total_parts': -(-args['file_size'] // part)})
        if rest[:2] == ['files', 'upload_sessions'] and len(rest) == 3 and self.command == 'PUT':
            session = SESSIONS.get(rest[2])
            match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', self.headers.get('Content-Range', ''))
            digest = 'sha=' + base64.b64encode(hashlib.sha1(body).digest()).decode()
            if session is None or match is None or self.headers.get('Digest') != digest or int(match.group(2)) - int(match.group(1)) + 1 != len(body):
                return self.send(400, b'bad part')
            part = {'part_id': uuid.uuid4().hex[:8], 'offset': int(match.group(1)), 'size': len(body), 'sha1': hashlib.sha1(body).hexdigest()}
            session['parts'][part['part_id']] = (part, body)
            return self.send(200, {'part': part})
        if rest[:2] == ['files', 'upload_sessions'] and len(rest) == 4 and rest[3] == 'commit':
            session = SESSIONS.pop(rest[2], None)
            if session is None:
                return self.send(404)
            listed = json.loads(body)['parts']
            data = b''.join(session['parts'][p['part_id']][1] for p in sorted(listed, key=lambda p: p['offset']))
            if len(data) != session['size'] or self.headers.get('Digest') != 'sha=' + base64.b64encode(hashlib.sha1(data).digest()).decode():
                return self.send(400, b'bad commit digest')
            return self.box_commit(session['name'], session['parent'], session['existing'], data)
        return self.send(400, b'unsupported box upload request')

    # Google Drive -----------------------------------------------------------------------------------

    def g_item(self, n):
        return {'id': n['id'], 'name': n['name'] or 'My Drive', 'mimeType': FOLDER_MIME if n['folder'] else n.get('mime', 'application/octet-stream'),
                'size': None if n['folder'] else str(len(n['data'])), 'modifiedTime': ISO, 'version': str(n['rev']),
                'parents': [] if n['parent'] is None else [n['parent']]}

    def g_lookup(self, gid):
        gid = ROOT_IDS['googledrive'] if gid == 'root' else gid
        n = NODES.get(gid)
        return n if n is not None and n['service'] == 'googledrive' and not n['trashed'] else None

    def google(self, path, query, body):
        if path.startswith('/google/upload/drive/v3/'):
            return self.google_start(path[len('/google/upload/drive/v3/'):], query, body)
        rest = path[len('/google/drive/v3/'):].split('/')
        if rest == ['about']:
            return self.send(200, {'user': {'emailAddress': 'fixture@google.test'}})
        if rest == ['files'] and self.command == 'GET':
            match = re.fullmatch(r"'((?:[^'\\]|\\.)*)' in parents(?: and name = '((?:[^'\\]|\\.)*)')? and trashed = false", query.get('q', ''))
            if match is None:
                return self.send(400, b'unsupported q')
            unescape = lambda s: re.sub(r'\\(.)', r'\1', s)
            parent = self.g_lookup(unescape(match.group(1)))
            if parent is None:
                return self.send(404)
            found = [k for k in kids(parent['id']) if match.group(2) is None or k['name'] == unescape(match.group(2))]
            return self.send(200, {'files': [self.g_item(k) for k in found]})
        if rest == ['files'] and self.command == 'POST':
            args = json.loads(body)
            parent = self.g_lookup(args['parents'][0])
            if parent is None:
                return self.send(404)
            return self.send(200, self.g_item(new_node('googledrive', parent['id'], args['name'], args.get('mimeType') == FOLDER_MIME)))
        n = self.g_lookup(rest[1])
        if n is None:
            return self.send(404)
        if self.command == 'GET':
            return self.content(n['data']) if query.get('alt') == 'media' else self.send(200, self.g_item(n))
        if self.command == 'PATCH':
            args = json.loads(body)
            if args.get('trashed'):
                n['trashed'] = True
            if 'name' in args:
                n['name'] = args['name']
            if query.get('addParents'):
                if query.get('removeParents') != n['parent'] or self.g_lookup(query['addParents']) is None:
                    return self.send(400, b'bad parents')
                n['parent'] = query['addParents']
            n['rev'] = bump()
            return self.send(200, self.g_item(n))
        return self.send(400, b'unsupported google request')

    def google_start(self, op, query, body):
        if query.get('uploadType') != 'resumable':
            return self.send(400)
        rest = op.split('/')
        sid = uuid.uuid4().hex
        if rest == ['files'] and self.command == 'POST':
            args = json.loads(body)
            if self.g_lookup(args['parents'][0]) is None:
                return self.send(404)
            SESSIONS[sid] = {'create': args}
        elif len(rest) == 2 and self.command == 'PATCH':
            if self.g_lookup(rest[1]) is None:
                return self.send(404)
            SESSIONS[sid] = {'update': rest[1]}
        else:
            return self.send(400)
        return self.send(200, b'', {'Location': self.server.endpoint + '/google-upload/' + sid})

    def google_finish(self, sid, body):
        session = SESSIONS.pop(sid, None)
        if session is None or self.command != 'PUT':
            return self.send(404)
        if 'create' in session:
            args = session['create']
            return self.send(200, {'id': new_node('googledrive', args['parents'][0], args['name'], False, body)['id']})
        n = self.g_lookup(session['update'])
        if n is None:
            return self.send(404)
        n.update(data=body, rev=bump())
        return self.send(200, {'id': n['id']})

    def do_GET(self): self.dispatch()
    def do_PUT(self): self.dispatch()
    def do_POST(self): self.dispatch()
    def do_PATCH(self): self.dispatch()
    def do_DELETE(self): self.dispatch()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--ready-file', required=True)
    args = parser.parse_args()
    reset()
    server = LoopbackHTTPServer(('127.0.0.1', 0), Handler)
    server.endpoint = f'http://127.0.0.1:{server.server_port}'
    with open(args.ready_file, 'w') as file:
        file.write(server.endpoint)
    server.serve_forever()
