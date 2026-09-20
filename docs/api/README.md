# API reference

LiteVMM's HTTP API is the same interface the web console uses. Everything the
console can do, a script can do with `curl`.

- **Conventions** (this page): authentication, request and response formats,
  errors, capabilities, the peer API and the proxy.
- **[Endpoint reference](endpoints.md)**: every route, grouped by area.

## Base URL and transport

```
http(s)://HOST:5186/api/
```

The API is served by the host's web server (lighttpd on Alpine, nginx on
Debian), which passes `/api/` to a single Bash CGI router (`cgi/api.cgi`)
through FastCGI. Each request runs as the unprivileged `vmapi` user. The router
validates input and calls the same `*ctl` shell commands an administrator would
run over SSH; privileged operations go through narrowly scoped `sudo` rules.
See [Architecture](../technical/architecture.md).

## Authentication

Every route requires **HTTP Basic** authentication, the same credentials as the
console login:

| Platform | Users |
|---|---|
| Alpine (lighttpd) | `/etc/lighttpd/vmapi.htpasswd`, created by the installer |
| Debian (nginx) | Local Linux accounts through PAM (`nginx-vmapi` service) |

```sh
curl -u alice http://10.0.1.185:5186/api/
```

Basic credentials are only encoded, so use HTTPS on any untrusted network.

Paired hosts do **not** use these accounts. They call `/peer-api/` with the
pair's own credential (see [Peer API](#the-peer-api)).

## Requests

| Aspect | Rule |
|---|---|
| Parameters | `application/x-www-form-urlencoded`, in the query string, the request body, or both (the body wins on conflicts). Maximum body size for forms: **1 MiB**; larger returns `413` |
| Parameter names | `[A-Za-z0-9_.-]`, up to 64 characters; other names are ignored |
| Repeatable values | Indexed names: `env_0`, `env_1`, …, `publish_0`, … |
| Booleans | The literal strings `true` / `false` |
| Uploads | Raw request body (not multipart) on the `PUT` routes marked *raw body*; the file name is in the path or query string |
| Methods | As listed per route; the wrong method returns `405` with a hint such as `Use GET or POST` |

Updates to single settings use a field/value pair:

```sh
curl -u alice -X PATCH --data 'field=memory&value=2g' \
  http://10.0.1.185:5186/api/docker/containers/web
```

## Responses

- JSON with `Content-Type: application/json` and `Cache-Control: no-store`,
  unless the route says otherwise.
- Downloads (`application/octet-stream`, `application/gzip`,
  `application/zip`) stream with `Content-Disposition: attachment`.
- Logs, Compose files, CSRs and pairing bundles return `text/plain`.
- Collections are JSON arrays; single objects are JSON objects. Many objects
  pass through the underlying tool's JSON unchanged (for example Docker
  inspect data), so their fields follow that tool.

## Errors

Errors are JSON with one field:

```json
{"error":"VM must be stopped before migration: web01"}
```

| Status | Meaning |
|---|---|
| `400 Bad Request` | Invalid input, or the underlying command failed. The message is the command's error output |
| `401 Unauthorized` | Missing or wrong credentials (from the web server), or a peer that is no longer trusted |
| `403 Forbidden` | A local-administration route called through the peer API |
| `404 Not Found` | Unknown route or object, **or a missing capability** (below) |
| `405 Method Not Allowed` | Wrong HTTP method |
| `413 Payload Too Large` | Form body over 1 MiB |
| `500 Internal Server Error` | Unexpected local failure (identity, cluster state) |
| `502 Bad Gateway` | A peer call failed. The message contains the peer's own error |

Because failures report the command's own message, the `error` string is
usually specific enough to act on without reading logs.

## Service discovery and capabilities

`GET /api/` describes the host:

```json
{
  "service": "litevmm",
  "version": 12,
  "profile": "virtualization-docker",
  "configured_profile": "virtualization-docker",
  "port": 5186,
  "tls_enabled": false,
  "user": "blaize",
  "capabilities": ["api","system","metrics","cluster","admin","backup",
    "backup-storage","qemu-kvm","backup-create","vm-network","vm-console",
    "storage","cloud-init","replication-source","docker","compose",
    "container-terminal","registry","peer-volume-client","backplane-client",
    "storage-backplane","files","host-terminal"]
}
```

Route groups are gated by capability. A call to a gated route on a host without
the capability returns `404` with
`Capability is not installed or available on this host: CAP`.

| Route prefix | Required capability |
|---|---|
| `/backups` | `backup` (and creation, scheduling and restore are refused on `backup`-profile hosts) |
| `/replications/replicas` | `storage-backplane` |
| `/replications` (all else) | `replication-source` |
| `/backplane` | `storage-backplane` |
| `/vms`, `/images`, `/migrations`, `/storage`, `/networks`, `/overlays` | `qemu-kvm` |
| `/docker`, `/compose` | `docker` (`/docker/peer-volumes` also `peer-volume-client`) |
| `/files` | `files` |
| `/host` | `host-terminal` |
| `/`, `/cluster`, `/logs`, `/metrics`, `/system`, `/admin` | none |

Check `capabilities` before calling optional routes, especially when iterating
over peers.

## The peer API

Paired hosts call each other at:

```
http(s)://PEER:5186/peer-api/<same path as /api/>
```

`/peer-api/` reaches the same router as `/api/`, with two differences:

1. **Authentication** uses the pair's HTTP Basic credential, checked by the web
   server against `/etc/vmapi-peer.htpasswd`, and then re-checked by the router
   against the live peer list, so revocation takes effect immediately.
2. **Local-administration routes are refused** with `403`:
   `/backplane/*`, `/docker/images/federated`, `/docker/images/prepare` and
   `/docker/images/pull`.

Some routes behave differently when called by a peer. For example, `POST
/overlays` from a peer creates only the local endpoint, bound to the calling
peer.

Clients normally never call `/peer-api/` directly; they use the proxy.

## The peer proxy

To operate a paired host through your own host, wrap any API path:

```
METHOD /api/cluster/peers/NODE_ID/proxy?path=/ENCODED/PATH
```

```sh
# List containers on peer 1dc34747… through the local host
curl -u alice "http://10.0.1.185:5186/api/cluster/peers/1dc34747e9c4543aa61306787a444ed7/proxy?path=%2Fdocker%2Fcontainers"
```

The local host forwards the method, content type and body (streamed, so
uploads work) to the peer's `/peer-api/`, authenticating with the pair's
credential. The caller never handles peer credentials. On success the proxy
returns `200` with the peer's body; on any peer error it returns `502` with the
peer's error text. The path must start with `/`, must not contain `..`, and
must not itself start with `/api` or `/peer-api`.

## Quick examples

```sh
H=http://10.0.1.185:5186/api
# Host health
curl -su alice $H/metrics
# Create and start a VM
curl -su alice -X POST --data 'name=web01&memory_mb=2048&vcpus=2&disk_size=20G&network=nat' $H/vms
curl -su alice -X POST $H/vms/web01/start
# Upload an ISO (raw body)
curl -su alice -X PUT --data-binary @alpine.iso $H/images/alpine.iso
# Back up a running VM to a peer
curl -su alice -X POST --data 'name=web01&live=true&peer_id=1dc34747e9c4543aa61306787a444ed7' $H/backups/start
# Run a container
curl -su alice -X POST --data 'name=web&image=nginx:latest&publish_0=8080:80&restart=unless-stopped' $H/docker/containers
```

A black-box regression suite exercising the public API is shipped as
`tests/api-regression-curl.sh` (installed as `vmapi-api-regression`).
