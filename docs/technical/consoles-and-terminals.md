# Consoles and terminals

Interactive sessions reuse the management port. Each is loopback-only behind
the web server and is created only after an authenticated API request.

## VM console (noVNC)

| Piece | Detail |
|---|---|
| QEMU | `-vnc 127.0.0.1:N` per VM (port `5900+N`), plus QMP and serial Unix sockets in `vms/NAME/runtime/` |
| Bridge | One short-lived GOST `forward` + `ws` service per active console, bound to an allocated loopback port |
| Web route | Exact `/console/ws/TOKEN` route → that session's loopback GOST port (lighttpd only) |
| Client | `/console.html` loads the packaged noVNC `RFB` module from `/novnc/` |

Flow: `POST /api/vms/NAME/console/session` → `consolectl start` creates a
random token and starts a GOST WebSocket-to-TCP forwarder targeting that VM's
VNC host and port → `consolectl` generates the exact Lighttpd token route →
the page connects to `/console/ws/TOKEN` → GOST emits the WebSocket payload
as ordinary TCP to QEMU VNC.

The GOST listener, QEMU VNC listener and generated proxy target are all
loopback-only. The normal console authentication still protects the WebSocket
route at Lighttpd.

Sessions expire after **120 s** without a heartbeat. The page sends
`PATCH …/console/session` every 30 s and `DELETE` when closed cleanly;
`vmapi-console-gc` stops stale GOST forwarders and removes their routes.

## Terminals (ttyd)

| Terminal | ttyd | Route | Command |
|---|---|---|---|
| Container | `127.0.0.1:7681` | `/docker/terminal/` | `dockerexecctl attach TOKEN` → `docker exec -it CONTAINER SHELL` |
| Host | `127.0.0.1:7682` | `/host/terminal/` | `hostexecctl attach` → root login shell |

`ttyd` runs with `--url-arg`, so the browser passes the token as a URL
argument. The attach command validates it (32 hex characters, a matching
session, not expired; container sessions last 15 minutes without a heartbeat)
before starting a shell. Without a valid token, ttyd has nothing to run.

Both terminals are also protected by the console login at the web server.

## Serial console

Each VM exposes `runtime/serial.sock`. It is not published over HTTP. Use it on
the host:

```sh
socat -,raw,echo=0 UNIX-CONNECT:/var/lib/vmapi/vms/NAME/runtime/serial.sock
```
