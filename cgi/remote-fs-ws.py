#!/usr/bin/env python3
import base64, errno, hashlib, json, os, re, stat, struct, sys
from pathlib import Path

SHARE_ROOT = Path(os.environ.get('VMAPI_REMOTE_VOLUME_SHARE_ROOT', '/var/lib/vmapi/remote-volume-shares'))
GUID = b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
MAX_FRAME = 4 * 1024 * 1024

class ProtocolError(Exception):
    pass

def read_exact(rd, n):
    out = bytearray()
    while len(out) < n:
        chunk = rd.read(n - len(out))
        if not chunk:
            raise EOFError
        out += chunk
    return bytes(out)

def ws_send(wr, payload, opcode=1):
    if isinstance(payload, str):
        payload = payload.encode()
    n = len(payload)
    head = bytearray([0x80 | opcode])
    if n < 126:
        head.append(n)
    elif n < 65536:
        head += bytes([126]) + struct.pack('!H', n)
    else:
        head += bytes([127]) + struct.pack('!Q', n)
    wr.write(head + payload)
    wr.flush()

def ws_recv(rd, wr):
    while True:
        h = read_exact(rd, 2)
        fin, opcode = bool(h[0] & 0x80), h[0] & 0x0f
        masked, n = bool(h[1] & 0x80), h[1] & 0x7f
        if not fin:
            raise ProtocolError('fragmented websocket frames are not supported')
        if n == 126:
            n = struct.unpack('!H', read_exact(rd, 2))[0]
        elif n == 127:
            n = struct.unpack('!Q', read_exact(rd, 8))[0]
        if n > MAX_FRAME:
            raise ProtocolError('websocket frame exceeds limit')
        mask = read_exact(rd, 4) if masked else None
        data = bytearray(read_exact(rd, n))
        if mask:
            for i in range(n):
                data[i] ^= mask[i % 4]
        if opcode == 0x8:
            return None
        if opcode == 0x9:
            ws_send(wr, data, opcode=0xA)
            continue
        if opcode == 0xA:
            continue
        if opcode not in (0x1, 0x2):
            raise ProtocolError('unsupported websocket opcode')
        return bytes(data)

def cgi_upgrade(rd, wr):
    if os.environ.get('HTTP_UPGRADE', '').lower() != 'websocket':
        wr.write(b'Status: 426 Upgrade Required\r\nContent-Type: text/plain\r\n\r\nWebSocket required\n')
        wr.flush(); return False
    key = os.environ.get('HTTP_SEC_WEBSOCKET_KEY', '')
    if not key:
        raise ProtocolError('missing websocket key')
    accept = base64.b64encode(hashlib.sha1(key.encode() + GUID).digest()).decode()
    wr.write((
        'Status: 101 Switching Protocols\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        f'Sec-WebSocket-Accept: {accept}\r\n\r\n'
    ).encode())
    wr.flush(); return True

def token_from_env():
    path = os.environ.get('PATH_INFO', '') or os.environ.get('REQUEST_URI', '')
    m = re.search(r'/([a-f0-9]{48})(?:/)?(?:\?.*)?$', path)
    if not m:
        raise PermissionError(errno.ENOENT, 'remote volume token not found')
    return m.group(1)

def load_share(token, remote_user):
    if not re.fullmatch(r'[A-Za-z0-9._-]{1,64}', remote_user or ''):
        raise PermissionError(errno.EACCES, 'paired user is required')
    for f in SHARE_ROOT.glob('*.json'):
        try:
            data = json.loads(f.read_text())
        except Exception:
            continue
        if data.get('token') != token:
            continue
        if not data.get('active', True):
            raise PermissionError(errno.EACCES, 'remote volume is inactive')
        if data.get('owner') != remote_user:
            raise PermissionError(errno.EACCES, 'remote volume belongs to another peer')
        root = Path(data['data']).resolve()
        root.mkdir(parents=True, exist_ok=True)
        return f, data, root
    raise FileNotFoundError(errno.ENOENT, 'remote volume not found')

def ensure_still_active(meta_file, token, owner):
    try:
        d = json.loads(meta_file.read_text())
        return d.get('token') == token and d.get('owner') == owner and d.get('active', True)
    except Exception:
        return False

def safe_path(root, value, missing_ok=True):
    if not isinstance(value, str) or not value.startswith('/') or '\x00' in value:
        raise OSError(errno.EINVAL, 'invalid path')
    rel = os.path.normpath(value).lstrip('/')
    if rel == '.':
        rel = ''
    candidate = root / rel
    if not rel:
        return root
    parent = candidate.parent.resolve()
    if os.path.commonpath([str(root), str(parent)]) != str(root):
        raise OSError(errno.EACCES, 'path escapes remote volume')
    if candidate.exists() or candidate.is_symlink():
        if candidate.is_symlink():
            raise OSError(errno.ELOOP, 'symbolic links are not supported by LiteVMM remote volumes')
        resolved = candidate.resolve()
        if os.path.commonpath([str(root), str(resolved)]) != str(root):
            raise OSError(errno.EACCES, 'path escapes remote volume')
    elif not missing_ok:
        raise OSError(errno.ENOENT, 'path not found')
    return candidate

def virtual_stat(path):
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        raise OSError(errno.ELOOP, 'symbolic links are not supported')
    mode = st.st_mode
    uid = 0; gid = 0
    try:
        mode = (stat.S_IFMT(st.st_mode) | int(os.getxattr(path, b'user.litevmm.mode').decode(), 8))
    except OSError:
        mode = stat.S_IFMT(st.st_mode) | (0o777 if stat.S_ISDIR(st.st_mode) else 0o666)
    try: uid = int(os.getxattr(path, b'user.litevmm.uid'))
    except OSError: pass
    try: gid = int(os.getxattr(path, b'user.litevmm.gid'))
    except OSError: pass
    return {
        'mode': mode, 'nlink': st.st_nlink, 'uid': uid, 'gid': gid, 'rdev': st.st_rdev,
        'size': st.st_size, 'atime_ns': st.st_atime_ns, 'mtime_ns': st.st_mtime_ns,
        'ctime_ns': st.st_ctime_ns, 'blocks': getattr(st, 'st_blocks', (st.st_size + 511)//512),
        'blksize': getattr(st, 'st_blksize', 4096),
    }

def set_virtual_meta(path, mode=None, uid=None, gid=None):
    if mode is not None:
        os.setxattr(path, b'user.litevmm.mode', f'{mode & 0o7777:o}'.encode())
    if uid is not None:
        os.setxattr(path, b'user.litevmm.uid', str(int(uid)).encode())
    if gid is not None:
        os.setxattr(path, b'user.litevmm.gid', str(int(gid)).encode())

def serve(root, meta_file, token, owner, rd, wr):
    handles = {}; next_handle = 1
    def response(reqid, **kw):
        kw['id'] = reqid; kw.setdefault('ok', True); ws_send(wr, json.dumps(kw, separators=(',', ':')))
    def get_handle(value):
        try:
            return handles[int(value)]
        except (KeyError, TypeError, ValueError):
            raise OSError(errno.EBADF, 'remote file handle is no longer valid')
    while True:
        raw = ws_recv(rd, wr)
        if raw is None:
            break
        try:
            req = json.loads(raw.decode())
            rid = req.get('id')
            if not ensure_still_active(meta_file, token, owner):
                raise OSError(errno.ESTALE, 'remote volume was disabled')
            op = req.get('op')
            if op == 'ping': response(rid, pong=True); continue
            if op == 'stat': response(rid, stat=virtual_stat(safe_path(root, req['path'], False))); continue
            if op == 'list':
                p = safe_path(root, req['path'], False)
                items=[]
                for name in sorted(os.listdir(p)):
                    q=p/name
                    if q.is_symlink(): continue
                    items.append({'name':name,'stat':virtual_stat(q)})
                response(rid, items=items); continue
            if op == 'open':
                p=safe_path(root, req['path'], False); flags=int(req.get('flags', os.O_RDONLY)) | getattr(os,'O_NOFOLLOW',0)
                fd=os.open(p, flags); h=next_handle; next_handle += 1; handles[h]=fd; response(rid, handle=h); continue
            if op == 'create':
                p=safe_path(root, req['path']); flags=int(req.get('flags', os.O_RDWR)) | os.O_CREAT | getattr(os,'O_NOFOLLOW',0)
                fd=os.open(p, flags, 0o660); set_virtual_meta(p, int(req.get('mode',0o666)), req.get('uid',0), req.get('gid',0)); h=next_handle; next_handle += 1; handles[h]=fd; response(rid, handle=h, stat=virtual_stat(p)); continue
            if op == 'read':
                fd=get_handle(req.get('handle')); data=os.pread(fd, min(int(req['size']), 1024*1024), int(req['offset'])); response(rid, data=base64.b64encode(data).decode()); continue
            if op == 'write':
                fd=get_handle(req.get('handle')); data=base64.b64decode(req.get('data',''), validate=True); n=os.pwrite(fd,data,int(req['offset'])); response(rid, written=n); continue
            if op == 'fsync': os.fsync(get_handle(req.get('handle'))); response(rid); continue
            if op == 'release':
                fd=handles.pop(int(req['handle']), None)
                if fd is not None: os.close(fd)
                response(rid); continue
            if op == 'mkdir':
                p=safe_path(root,req['path']); os.mkdir(p,0o770); set_virtual_meta(p,int(req.get('mode',0o777)),req.get('uid',0),req.get('gid',0)); response(rid,stat=virtual_stat(p)); continue
            if op == 'unlink': os.unlink(safe_path(root,req['path'],False)); response(rid); continue
            if op == 'rmdir': os.rmdir(safe_path(root,req['path'],False)); response(rid); continue
            if op == 'rename': os.rename(safe_path(root,req['old'],False),safe_path(root,req['new'])); response(rid); continue
            if op == 'truncate': os.truncate(safe_path(root,req['path'],False),int(req['size'])); response(rid,stat=virtual_stat(safe_path(root,req['path'],False))); continue
            if op == 'chmod':
                p=safe_path(root,req['path'],False); set_virtual_meta(p,mode=int(req['mode'])); response(rid,stat=virtual_stat(p)); continue
            if op == 'chown':
                p=safe_path(root,req['path'],False); set_virtual_meta(p,uid=req.get('uid'),gid=req.get('gid')); response(rid,stat=virtual_stat(p)); continue
            if op == 'utimens':
                p=safe_path(root,req['path'],False); os.utime(p, ns=(int(req['atime_ns']),int(req['mtime_ns']))); response(rid,stat=virtual_stat(p)); continue
            if op == 'statfs':
                st=os.statvfs(root); response(rid,statfs={k:getattr(st,k) for k in ('f_bsize','f_frsize','f_blocks','f_bfree','f_bavail','f_files','f_ffree','f_favail','f_namemax')}); continue
            raise OSError(errno.ENOSYS, f'unsupported operation: {op}')
        except OSError as e:
            ws_send(wr, json.dumps({'id': req.get('id') if 'req' in locals() else None, 'ok':False, 'errno':e.errno or errno.EIO, 'error':str(e)}, separators=(',',':')))
        except Exception as e:
            ws_send(wr, json.dumps({'id': req.get('id') if 'req' in locals() else None, 'ok':False, 'errno':errno.EIO, 'error':str(e)}, separators=(',',':')))
    for fd in handles.values():
        try: os.close(fd)
        except OSError: pass

def main():
    rd=os.fdopen(sys.stdin.fileno(),'r+b',buffering=0); wr=os.fdopen(sys.stdout.fileno(),'r+b',buffering=0)
    try:
        token=token_from_env(); owner=os.environ.get('REMOTE_USER',''); meta,data,root=load_share(token,owner)
        if not cgi_upgrade(rd,wr): return
        serve(root,meta,token,owner,rd,wr)
    except Exception as e:
        try:
            wr.write(f'Status: 403 Forbidden\r\nContent-Type: text/plain\r\n\r\n{e}\n'.encode()); wr.flush()
        except Exception: pass

if __name__=='__main__': main()
