# LiteVMM Storage

The runtime image is based on **Alpine Linux 3.24**.

LiteVMM Storage is the containerized backup and peer-storage node for [LiteVMM](https://github.com/theonemule/LiteVMM).

It provides the LiteVMM backup profile without installing the VM or Docker workload runtimes. Paired LiteVMM hosts can use it for VM backups, retained VM replicas, peer-backed Docker volumes, shared media, registry data, and other filesystem-backed peer storage.

Full source, documentation, issue tracking, and release history are available in the GitHub project:

**https://github.com/theonemule/LiteVMM**

## Unprivileged container

The storage image runs as a normal unprivileged Docker container. It uses UNFS3, a userspace NFSv3 server, on a high loopback-only port inside the container. It does **not** require `--privileged`, `CAP_SYS_ADMIN`, `CAP_DAC_READ_SEARCH`, host mount capabilities, `/dev/fuse`, or access to the host kernel NFS server.

The NFS service is never published. LiteVMM carries its traffic through the existing authenticated `/backplane/storage` WebSocket endpoint on the management port.

## Run

```bash
docker run -d \
  --name litevmm-storage \
  --restart unless-stopped \
  -p 5186:5186 \
  -p 5187:5187 \
  -e VMAPI_HTTP_USER=admin \
  -e VMAPI_HTTP_PASSWORD='choose-a-strong-password' \
  -v litevmm-storage-data:/var/lib/vmapi \
  blaize/litevmm-storage:latest
```

Open the LiteVMM management UI on port `5186` and pair the storage node with another LiteVMM host. Port `5187` is the default secondary HTTPS port used by the `dual` and `redirect` certificate policies.

## TrueNAS SCALE

Deploy `blaize/litevmm-storage:latest` as a Custom App with **Privileged disabled** and with **no additional capabilities**.

Configure only:

- TCP port `5186` published to the host.
- TCP port `5187` published if you want to keep HTTP and HTTPS simultaneously or redirect HTTP to HTTPS. It is not needed for the `replace` policy.
- `VMAPI_HTTP_USER`.
- `VMAPI_HTTP_PASSWORD`.
- Persistent storage mounted at `/var/lib/vmapi`.

Do not publish the internal NFS port or WebSocket bridge port. The storage image uses internal port `12049` for userspace NFS and `6091` for the loopback WebSocket bridge; neither needs a TrueNAS port mapping.

### HTTPS transport policy

Issuing or importing a certificate does not immediately change the listener. The administration page stages the certificate and asks how to activate it:

- `dual` keeps HTTP on `5186` and adds HTTPS on `5187`. Existing peers configured with `http://...:5186` continue working.
- `redirect` keeps `5186` as an HTTP redirect and serves HTTPS on `5187`. Existing API/WebSocket clients must support the redirect or have their endpoint updated.
- `replace` changes `5186` from HTTP to HTTPS and does not use the secondary listener. Existing peers configured for HTTP on `5186` must be updated.

For TrueNAS, publish container port `5187` when using `dual` or `redirect`. Keep the host and container port the same unless you intentionally account for the external port in the URL presented to users.

Certificate files, the local CA, and TLS activation state are persisted below `/var/lib/vmapi`. On upgrade, the container recognizes the legacy state where certificate files survived but the old config incorrectly reported TLS as disabled. A user-initiated disable is recorded explicitly and will remain disabled across container recreation. The UI can either disable HTTPS while retaining the certificate or remove the managed endpoint certificate and return to HTTP; removing an endpoint certificate retains the LiteVMM root CA.

## Persistent data

Mount `/var/lib/vmapi` as a named volume or bind mount. This contains the node identity, peer configuration, TLS material, backup metadata, and the peer storage tree.

Example with a host directory:

```bash
mkdir -p /srv/litevmm-storage

docker run -d \
  --name litevmm-storage \
  --restart unless-stopped \
  -p 5186:5186 \
  -p 5187:5187 \
  -e VMAPI_HTTP_USER=admin \
  -e VMAPI_HTTP_PASSWORD='choose-a-strong-password' \
  -v /srv/litevmm-storage:/var/lib/vmapi \
  blaize/litevmm-storage:latest
```

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `VMAPI_HTTP_PORT` | `5186` | Existing management HTTP port. In `replace` mode this port becomes HTTPS. |
| `VMAPI_HTTPS_PORT` | `5187` | Secondary HTTPS port used by `dual` and `redirect` policies. |
| `VMAPI_HTTP_USER` | `admin` | Management UI/API username |
| `VMAPI_HTTP_PASSWORD` | required | Management UI/API password |

## Build from source

Clone the project and build from the repository root:

```bash
git clone https://github.com/theonemule/LiteVMM.git
cd LiteVMM

docker build \
  -f docker/storage/Dockerfile \
  --build-arg LITEVMM_VERSION="$(cat VERSION)" \
  -t blaize/litevmm-storage:latest \
  .
```

## Project

LiteVMM is a minimalist infrastructure API and web console for backup storage, QEMU/KVM virtualization, and Docker management.

GitHub: https://github.com/theonemule/LiteVMM

Documentation: https://github.com/theonemule/LiteVMM-Docs
