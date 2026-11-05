# Crawl4AI server image

A Nix-built, non-root Crawl4AI API image using pkgs.dockerTools. It packages the upstream server files and a pinned Python dependency environment; it does not use an upstream OCI base image.

## Source and build

- Upstream: [Crawl4AI](https://github.com/unclecode/crawl4ai), v0.9.5, commit 838869bdda93f25e6d50b3f50ae9577d9b19a586.
- The Python server dependencies are locked in uv.lock; Nixpkgs and Nix flake inputs are locked in flake.lock.
- The image is currently supported on x86_64-linux.
- Published image: `ghcr.io/rogernavelsaker/crawl4ai:0.9.5`.

~~~sh
nix flake check
nix build .#image
~~~

The checks import the API, launch sandboxed Chromium against local HTML, and start the entrypoint with Valkey to verify loopback binding, `/health`, and unauthenticated API denial. They make no external crawls.

The build output is a container image archive. No image import or deployment is performed by these commands.

## Runtime contract

- Runs as numeric UID/GID 10001:10001.
- Starts the upstream entrypoint and supervisord. Supervisord runs the API with Gunicorn/Uvicorn and an internal Valkey server; Valkey listens only on loopback and requires a password.
- API TCP port: 11235. The public GET /health endpoint backs the image healthcheck.
- Without CRAWL4AI_API_TOKEN or CRAWL4AI_JWT_ENABLED=true, the upstream entrypoint binds the API to container loopback. Configure authentication before exposing the service to other containers or hosts.
- Supply CRAWL4AI_API_TOKEN and REDIS_PASSWORD through a secret manager or the upstream /run/secrets/api_token and /run/secrets/redis_password files; file-mounted secrets must be readable by UID 10001. If no Redis password is supplied, the entrypoint generates an ephemeral one. Set SECRET_KEY through a secret manager when stable JWT signing is required.
- The default config is /app/config.yml; mount a custom config there read-only.

## Writable paths and read-only root

- /data: HOME, Valkey persistence (/data/redis), and crawler artifacts (/data/artifacts). The entrypoint creates the Redis and artifacts directories when an empty volume is mounted.
- /tmp: supervisord PID file and transient browser/runtime files.
- The application and configuration files under /app are read-only to the runtime user. For a read-only root filesystem, provide writable /data storage and a /tmp tmpfs. Ensure the mounted data path is writable as container UID 10001 through an intentional user-namespace mapping.

The image keeps Chromium's sandbox enabled with CRAWL4AI_CHROMIUM_SANDBOX=true; the Nix browser closure is pinned through Nixpkgs and excludes Firefox, WebKit, and FFmpeg. On hosts whose default seccomp profile denies `chroot` when capabilities are dropped, Chromium exits during startup. For Podman, derive a narrow profile from the host default by removing its `chroot` rule and adding an unconditional syscall allow; Linux capability checks still apply, so keep `--cap-drop=all` and `no-new-privileges` enabled. Example (adjust the default profile path for the host):

```sh
profile=$(mktemp)
jq '.syscalls |= (map(select((.names | index("chroot")) == null)) + [{names:["chroot"],action:"SCMP_ACT_ALLOW",args:[],comment:"Chromium sandbox; retain capability checks",includes:{},excludes:{}}])' \
  /usr/share/containers/seccomp.json > "$profile"
# Add these options to the service's Podman run command:
# --security-opt="seccomp=$profile" --cap-drop=all --security-opt=no-new-privileges
rm -f "$profile"
```

Do not use `seccomp=unconfined` or disable Chromium's sandbox. Rootless browser launch still depends on host user-namespace support and the runtime's remaining policy. The image build itself does not prove those host settings.

No model weights are bundled, and the image build does not run crawl4ai-setup or download browsers at runtime.
