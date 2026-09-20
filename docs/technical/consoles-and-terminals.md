# Consoles and terminals

Interactive sessions reuse the management port. Each is a loopback-only
daemon behind the web server, unlocked by a short-lived token that the API
issues to an authenticated user.

## VM console (noVNC)

| Piece | Detail |
|---|---|
| QEMU | `-vnc 127.0.0.1:N` per VM (port `5900+N`), plus QMP and serial Unix sockets in `vms/NAME/runtime/` |
| Broker | One `websockify` on `127.0.0.1:6080` with the `TokenFile` plugin reading `/run/vmapi/console.tokens` |
| Web route | `/console/ws/` → `127.0.0.1:6080` (lighttpd only) |
| Client | `/console.html` loads the packaged noVNC `RFB` module from `/novnc/` |

Flow: `POST /api/vms/NAME/console/session` → `consolectl start` writes a random
token mapping to that VM's VNC host and port → the page connects to
`/console/ws/?token=…` → websockify looks up the token and bridges to QEMU's VNC.

Sessions expire after **120 s** without a heartbeat. The page sends
`PATCH …/console/session` every 30 s and `DELETE` when closed cleanly;
`vmapi-console-gc` prunes stale tokens. Because one broker serves every token,
any number of consoles can be open without web server changes.

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
