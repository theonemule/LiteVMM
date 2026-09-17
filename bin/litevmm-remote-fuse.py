#!/usr/bin/env python3
import argparse, base64, errno, hashlib, json, os, secrets, socket, ssl, struct, threading, stat
from urllib.parse import urlparse
import pyfuse3, trio

GUID = b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
MAX_FRAME = 4 * 1024 * 1024

class RemoteError(OSError):
    pass

class WebSocketRPC:
    def __init__(self, url, user, password):
        self.url=url; self.user=user; self.password=password; self.sock=None; self.lock=threading.Lock(); self.seq=0
    def close(self):
        s=self.sock; self.sock=None
        if s:
            try: self._send_frame(b'', opcode=0x8, sock=s)
            except Exception: pass
            try: s.close()
            except Exception: pass
    @staticmethod
    def _read_exact(sock,n):
        out=bytearray()
        while len(out)<n:
            b=sock.recv(n-len(out))
            if not b: raise EOFError('websocket closed')
            out += b
        return bytes(out)
    def _connect(self):
        self.close()
        u=urlparse(self.url)
        if u.scheme != 'wss': raise OSError(errno.EPROTONOSUPPORT,'LiteVMM remote volumes require wss://')
        host=u.hostname; port=u.port or 443
        raw=socket.create_connection((host,port),timeout=15)
        ca_file=os.environ.get('LITEVMM_REMOTE_FS_CA_FILE') or None
        ctx=ssl.create_default_context(cafile=ca_file)
        s=ctx.wrap_socket(raw,server_hostname=host)
        s.settimeout(60)
        key=base64.b64encode(secrets.token_bytes(16)).decode()
        auth=base64.b64encode(f'{self.user}:{self.password}'.encode()).decode()
        hosthdr=host if port==443 else f'{host}:{port}'
        path=u.path or '/'
        req=(f'GET {path} HTTP/1.1\r\nHost: {hosthdr}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
             f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Basic {auth}\r\nOrigin: https://{hosthdr}\r\n\r\n').encode()
        s.sendall(req)
        buf=bytearray()
        while b'\r\n\r\n' not in buf and len(buf)<65536:
            b=s.recv(4096)
            if not b: break
            buf += b
        head=bytes(buf).split(b'\r\n\r\n',1)[0].decode('latin1','replace')
        lines=head.split('\r\n')
        if not lines or ' 101 ' not in lines[0]:
            s.close(); raise OSError(errno.EACCES,f'WebSocket upgrade failed: {lines[0] if lines else "no response"}')
        headers={}
        for line in lines[1:]:
            if ':' in line:
                k,v=line.split(':',1); headers[k.strip().lower()]=v.strip()
        expected=base64.b64encode(hashlib.sha1(key.encode()+GUID).digest()).decode()
        if headers.get('sec-websocket-accept') != expected:
            s.close(); raise OSError(errno.EPROTO,'invalid WebSocket accept key')
        self.sock=s
    def _send_frame(self,data,opcode=1,sock=None):
        s=sock or self.sock
        if isinstance(data,str): data=data.encode()
        n=len(data); mask=secrets.token_bytes(4); head=bytearray([0x80|opcode])
        if n<126: head.append(0x80|n)
        elif n<65536: head += bytes([0x80|126])+struct.pack('!H',n)
        else: head += bytes([0x80|127])+struct.pack('!Q',n)
        head += mask
        payload=bytearray(data)
        for i in range(n): payload[i] ^= mask[i%4]
        s.sendall(head+payload)
    def _recv_frame(self):
        while True:
            h=self._read_exact(self.sock,2); opcode=h[0]&0x0f; n=h[1]&0x7f; masked=bool(h[1]&0x80)
            if n==126: n=struct.unpack('!H',self._read_exact(self.sock,2))[0]
            elif n==127: n=struct.unpack('!Q',self._read_exact(self.sock,8))[0]
            if n>MAX_FRAME: raise OSError(errno.EOVERFLOW,'WebSocket response too large')
            mask=self._read_exact(self.sock,4) if masked else None
            data=bytearray(self._read_exact(self.sock,n))
            if mask:
                for i in range(n): data[i]^=mask[i%4]
            if opcode==0x8: raise EOFError('WebSocket closed')
            if opcode==0x9: self._send_frame(data,opcode=0xA); continue
            if opcode==0xA: continue
            if opcode not in (0x1,0x2): continue
            return bytes(data)
    def call(self,op,**kwargs):
        with self.lock:
            self.seq += 1; rid=self.seq; req={'id':rid,'op':op,**kwargs}
            last=None
            for attempt in range(2):
                try:
                    if self.sock is None: self._connect()
                    self._send_frame(json.dumps(req,separators=(',',':')))
                    while True:
                        resp=json.loads(self._recv_frame().decode())
                        if resp.get('id') != rid: continue
                        if not resp.get('ok',False):
                            raise RemoteError(int(resp.get('errno') or errno.EIO),resp.get('error') or 'remote filesystem error')
                        return resp
                except RemoteError:
                    raise
                except Exception as e:
                    last=e; self.close()
                    if attempt: break
            if isinstance(last,OSError): raise last
            raise OSError(errno.EIO,str(last) if last else 'remote filesystem disconnected')

class RemoteFS(pyfuse3.Operations):
    enable_writeback_cache=False
    def __init__(self,rpc):
        super().__init__(); self.rpc=rpc; self.inode_path={pyfuse3.ROOT_INODE:'/'}; self.path_inode={'/':pyfuse3.ROOT_INODE}; self.next_inode=2; self.handles={}; self.next_fh=1; self.map_lock=threading.Lock()
    async def call(self,op,**kwargs):
        try: return await trio.to_thread.run_sync(lambda:self.rpc.call(op,**kwargs))
        except RemoteError as e: raise pyfuse3.FUSEError(e.errno or errno.EIO)
        except OSError as e: raise pyfuse3.FUSEError(e.errno or errno.EIO)
    def _path(self,inode):
        try:return self.inode_path[int(inode)]
        except KeyError: raise pyfuse3.FUSEError(errno.ENOENT)
    def _inode(self,path):
        with self.map_lock:
            if path in self.path_inode:return self.path_inode[path]
            i=self.next_inode; self.next_inode+=1; self.path_inode[path]=i; self.inode_path[i]=path; return i
    def _join(self,parent,name):
        n=os.fsdecode(name)
        p=self._path(parent)
        if n=='.': return p
        if n=='..': return os.path.dirname(p.rstrip('/')) or '/'
        return (p.rstrip('/')+'/'+n) if p!='/' else '/'+n
    def _attr(self,path,s):
        a=pyfuse3.EntryAttributes(); a.st_ino=self._inode(path); a.generation=0; a.entry_timeout=1; a.attr_timeout=1
        a.st_mode=int(s['mode']); a.st_nlink=int(s.get('nlink',1)); a.st_uid=int(s.get('uid',0)); a.st_gid=int(s.get('gid',0)); a.st_rdev=int(s.get('rdev',0)); a.st_size=int(s.get('size',0)); a.st_atime_ns=int(s.get('atime_ns',0)); a.st_mtime_ns=int(s.get('mtime_ns',0)); a.st_ctime_ns=int(s.get('ctime_ns',0)); a.st_blksize=int(s.get('blksize',4096)); a.st_blocks=int(s.get('blocks',(a.st_size+511)//512)); return a
    async def lookup(self,parent_inode,name,ctx=None):
        p=self._join(parent_inode,name); r=await self.call('stat',path=p); return self._attr(p,r['stat'])
    async def getattr(self,inode,ctx=None):
        p=self._path(inode); r=await self.call('stat',path=p); return self._attr(p,r['stat'])
    async def opendir(self,inode,ctx): return inode
    async def readdir(self,fh,start_id,token):
        p=self._path(fh); r=await self.call('list',path=p); items=r.get('items',[]); start=int(start_id)
        for i,item in enumerate(items[start:],start=start):
            child=self._join(fh,os.fsencode(item['name'])); attr=self._attr(child,item['stat'])
            if not pyfuse3.readdir_reply(token,os.fsencode(item['name']),attr,i+1): break
    async def releasedir(self,fh): return
    async def open(self,inode,flags,ctx):
        p=self._path(inode); r=await self.call('open',path=p,flags=int(flags)); fh=self.next_fh; self.next_fh+=1; self.handles[fh]={'path':p,'flags':int(flags) & ~(os.O_CREAT|os.O_EXCL|os.O_TRUNC),'remote':int(r['handle'])}; return pyfuse3.FileInfo(fh=fh)
    async def create(self,parent_inode,name,mode,flags,ctx):
        p=self._join(parent_inode,name); r=await self.call('create',path=p,mode=int(mode),flags=int(flags),uid=int(ctx.uid),gid=int(ctx.gid)); fh=self.next_fh; self.next_fh+=1; self.handles[fh]={'path':p,'flags':int(flags) & ~(os.O_CREAT|os.O_EXCL|os.O_TRUNC),'remote':int(r['handle'])}; return pyfuse3.FileInfo(fh=fh),self._attr(p,r['stat'])
    async def _handle_call(self,fh,op,**kwargs):
        h=self.handles.get(int(fh))
        if not h: raise pyfuse3.FUSEError(errno.EBADF)
        try:return await self.call(op,handle=h['remote'],**kwargs)
        except pyfuse3.FUSEError as e:
            if e.errno != errno.EBADF: raise
            r=await self.call('open',path=h['path'],flags=h['flags']); h['remote']=int(r['handle']); return await self.call(op,handle=h['remote'],**kwargs)
    async def read(self,fh,off,size):
        r=await self._handle_call(fh,'read',offset=int(off),size=min(int(size),1024*1024)); return base64.b64decode(r.get('data',''))
    async def write(self,fh,off,buf):
        total=0; data=bytes(buf)
        while total<len(data):
            chunk=data[total:total+512*1024]; r=await self._handle_call(fh,'write',offset=int(off)+total,data=base64.b64encode(chunk).decode()); n=int(r['written']); total+=n
            if n!=len(chunk): break
        return total
    async def flush(self,fh): return
    async def fsync(self,fh,datasync): await self._handle_call(fh,'fsync')
    async def release(self,fh):
        h=self.handles.pop(int(fh),None)
        if h:
            try: await self.call('release',handle=h['remote'])
            except pyfuse3.FUSEError: pass
    async def mkdir(self,parent_inode,name,mode,ctx):
        p=self._join(parent_inode,name); r=await self.call('mkdir',path=p,mode=int(mode),uid=int(ctx.uid),gid=int(ctx.gid)); return self._attr(p,r['stat'])
    async def mknod(self,parent_inode,name,mode,rdev,ctx):
        if not stat.S_ISREG(mode): raise pyfuse3.FUSEError(errno.ENOSYS)
        fi,attr=await self.create(parent_inode,name,mode,os.O_RDWR,ctx); await self.release(fi.fh); return attr
    async def unlink(self,parent_inode,name,ctx):
        p=self._join(parent_inode,name); await self.call('unlink',path=p); self.path_inode.pop(p,None)
    async def rmdir(self,parent_inode,name,ctx):
        p=self._join(parent_inode,name); await self.call('rmdir',path=p); self.path_inode.pop(p,None)
    async def rename(self,parent_inode_old,name_old,parent_inode_new,name_new,flags,ctx):
        if int(flags)!=0: raise pyfuse3.FUSEError(errno.EINVAL)
        old=self._join(parent_inode_old,name_old); new=self._join(parent_inode_new,name_new); await self.call('rename',old=old,new=new)
        with self.map_lock:
            updates=[]
            for p,i in list(self.path_inode.items()):
                if p==old or p.startswith(old.rstrip('/')+'/'): updates.append((p,new+p[len(old):],i))
            for p,np,i in updates: self.path_inode.pop(p,None); self.path_inode[np]=i; self.inode_path[i]=np
    async def setattr(self,inode,attr,fields,fh,ctx):
        p=self._path(inode)
        if fields.update_size: await self.call('truncate',path=p,size=int(attr.st_size))
        if fields.update_mode: await self.call('chmod',path=p,mode=int(attr.st_mode))
        if fields.update_uid or fields.update_gid: await self.call('chown',path=p,uid=int(attr.st_uid) if fields.update_uid else None,gid=int(attr.st_gid) if fields.update_gid else None)
        if fields.update_atime or fields.update_mtime or getattr(fields,'update_atime_now',False) or getattr(fields,'update_mtime_now',False):
            cur=(await self.call('stat',path=p))['stat']; now=__import__('time').time_ns(); at=now if getattr(fields,'update_atime_now',False) else (int(attr.st_atime_ns) if fields.update_atime else int(cur['atime_ns'])); mt=now if getattr(fields,'update_mtime_now',False) else (int(attr.st_mtime_ns) if fields.update_mtime else int(cur['mtime_ns'])); await self.call('utimens',path=p,atime_ns=at,mtime_ns=mt)
        return await self.getattr(inode,ctx)
    async def statfs(self,ctx):
        s=(await self.call('statfs'))['statfs']; v=pyfuse3.StatvfsData()
        for k in ('f_bsize','f_frsize','f_blocks','f_bfree','f_bavail','f_files','f_ffree','f_favail','f_namemax'): setattr(v,k,int(s[k]))
        return v
    async def access(self,inode,mode,ctx): return True
    async def readlink(self,inode,ctx): raise pyfuse3.FUSEError(errno.ENOSYS)
    async def symlink(self,parent_inode,name,target,ctx): raise pyfuse3.FUSEError(errno.ENOSYS)
    async def link(self,inode,new_parent_inode,new_name,ctx): raise pyfuse3.FUSEError(errno.ENOSYS)
    def destroy(self): self.rpc.close()

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('mountpoint'); args=ap.parse_args()
    url=os.environ.get('LITEVMM_REMOTE_FS_URL',''); user=os.environ.get('LITEVMM_REMOTE_FS_USER',''); password=os.environ.get('LITEVMM_REMOTE_FS_PASSWORD','')
    if not (url and user and password): raise SystemExit('remote filesystem URL and peer credentials are required')
    os.makedirs(args.mountpoint,exist_ok=True); rpc=WebSocketRPC(url,user,password); ops=RemoteFS(rpc)
    opts=set(pyfuse3.default_options); opts.add('fsname=litevmm-remote'); opts.add('allow_other'); opts.add('default_permissions')
    pyfuse3.init(ops,args.mountpoint,opts)
    try: trio.run(pyfuse3.main)
    except BaseException:
        pyfuse3.close(unmount=False); raise
    finally: rpc.close()
    pyfuse3.close()

if __name__=='__main__':
    main()
