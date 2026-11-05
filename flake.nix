{
  description = "Crawl4AI server image built with Nix dockerTools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crawl4ai-src = {
      url = "github:unclecode/crawl4ai/838869bdda93f25e6d50b3f50ae9577d9b19a586";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      crawl4ai-src,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;
      version = "0.9.5";
      revision = "838869bdda93f25e6d50b3f50ae9577d9b19a586";
      python = pkgs.python313;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
      overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
      nodeRuntimeOverlay = final: prev: {
        playwright = prev.playwright.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            ln -sf ${pkgs.nodejs_22}/bin/node "$out/${python.sitePackages}/playwright/driver/node"
          '';
        });
        patchright = prev.patchright.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            ln -sf ${pkgs.nodejs_22}/bin/node "$out/${python.sitePackages}/patchright/driver/node"
          '';
        });
      };

      pythonSet = (pkgs.callPackage pyproject-nix.build.packages { inherit python; })
        .overrideScope (lib.composeManyExtensions [
          pyproject-build-systems.overlays.wheel
          overlay
          nodeRuntimeOverlay
        ]);
      pythonEnv = pythonSet.mkVirtualEnv "crawl4ai-api-env" workspace.deps.default;
      browsers = pkgs.playwright-driver.selectBrowsers {
        withFirefox = false;
        withWebkit = false;
        withFfmpeg = false;
      };

      rawSupervisorConfig = builtins.readFile "${crawl4ai-src}/deploy/docker/supervisord.conf";
      supervisorConfig = pkgs.writeText "supervisord.conf" (
        lib.replaceStrings
          [
            "/usr/bin/redis-server"
            "/var/lib/redis"
            "/usr/local/bin/gunicorn"
          ]
          [
            "${pkgs.valkey}/bin/valkey-server"
            "/data/redis"
            "${pythonEnv}/bin/gunicorn"
          ]
          (lib.concatStringsSep "\n" (
            lib.filter
              (line: !(lib.hasPrefix "user=appuser" line))
              (lib.splitString "\n" rawSupervisorConfig)
          ))
      );

      runtimeFiles = pkgs.runCommand "crawl4ai-runtime-files" { } ''
        mkdir -p "$out/app" "$out/usr/share/licenses/crawl4ai"
        cp -a ${crawl4ai-src}/deploy/docker/. "$out/app/"
        chmod -R u+w "$out/app"
        substituteInPlace "$out/app/entrypoint.sh" \
          --replace-fail \
          'exec supervisord -c supervisord.conf --pidfile /tmp/supervisord.pid' \
          'mkdir -p /data/redis /data/artifacts
exec supervisord -c supervisord.conf --pidfile /tmp/supervisord.pid'
        cp ${crawl4ai-src}/LICENSE "$out/usr/share/licenses/crawl4ai/LICENSE"
        cp ${supervisorConfig} "$out/app/supervisord.conf"

        rm -rf "$out/app/tests" "$out/app/__pycache__"
        rm -f \
          "$out/app/.dockerignore" \
          "$out/app/.llm.env.example" \
          "$out/app/ARCHITECTURE.md" \
          "$out/app/MIGRATION.md" \
          "$out/app/README.md" \
          "$out/app/requirements.txt" \
          "$out/app/SECURITY-VERIFY.md" \
          "$out/app/STRESS_TEST_PIPELINE.md" \
          "$out/app/WEBHOOK_EXAMPLES.md" \
          "$out/app/test-websocket.py"

        chmod -R a-w "$out"
      '';

      apiImportCheck = pkgs.runCommand "crawl4ai-api-import-check" { } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export PYTHONPATH="${runtimeFiles}/app"
        export PYTHONDONTWRITEBYTECODE=1
        export CRAWL4AI_CHROMIUM_SANDBOX=true
        ${pythonEnv}/bin/python - <<'PY'
import os
import secrets

os.environ["SECRET_KEY"] = secrets.token_hex(32)
os.environ["CRAWL4AI_API_TOKEN"] = secrets.token_hex(32)
from crawl4ai.__version__ import __version__
import server

assert __version__ == "0.9.5"
assert server.app is not None
assert server.CHROMIUM_SANDBOX
assert "--no-sandbox" not in server._browser_extra_args()
print("Crawl4AI 0.9.5 API imports with Chromium sandbox enabled")
PY
        touch "$out"
      '';

      browserCheck = pkgs.runCommand "crawl4ai-browser-sandbox-check" { } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export PLAYWRIGHT_BROWSERS_PATH="${browsers}"
        export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
        export CRAWL4AI_CHROMIUM_SANDBOX=true
        ${pythonEnv}/bin/python - <<'PY'
import asyncio
from patchright.async_api import async_playwright

async def main():
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(headless=True, chromium_sandbox=True)
        try:
            page = await browser.new_page()
            await page.set_content("<h1>ok</h1>")
            document = await page.content()
            assert "<h1>ok</h1>" in document, f"expected local HTML in document: {document!r}"
        finally:
            await browser.close()

asyncio.run(main())
print("Patchright launched sandboxed Chromium against local HTML")
PY
        touch "$out"
      '';

      serviceHealthCheck = pkgs.runCommand "crawl4ai-service-health-check" { } ''
        mkdir -p "$TMPDIR/home"
        export HOME="$TMPDIR/home"
        export TMPDIR
        export PATH="${pythonEnv}/bin:${pkgs.python313Packages.supervisor}/bin:${pkgs.valkey}/bin:${pkgs.coreutils}/bin:${pkgs.bashNonInteractive}/bin"
        export CRAWL4AI_ARTIFACT_DIR="$TMPDIR/artifacts"
        export CRAWL4AI_CHROMIUM_SANDBOX=true
        export CRAWL4AI_PORT=5099
        export PLAYWRIGHT_BROWSERS_PATH="${browsers}"
        export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
        export PYTHONPATH="${runtimeFiles}/app"
        export REDIS_HOST=127.0.0.1
        export REDIS_PORT=16379
        ${pkgs.gnused}/bin/sed \
          -e "s|--dir /data/redis|--port 16379 --dir $TMPDIR/redis|" \
          -e "s|directory=/app|directory=${runtimeFiles}/app|" \
          "${runtimeFiles}/app/supervisord.conf" > "$TMPDIR/supervisord.conf"
        ${pkgs.gnused}/bin/sed \
          -e "s|--pidfile /tmp/supervisord.pid|--pidfile $TMPDIR/supervisord.pid|" \
          -e "s|/data/redis /data/artifacts|$TMPDIR/redis $TMPDIR/artifacts|" \
          "${runtimeFiles}/app/entrypoint.sh" > "$TMPDIR/entrypoint.sh"
        chmod +x "$TMPDIR/entrypoint.sh"
        ${pythonEnv}/bin/python - <<'PY'
import json, os, re, signal, subprocess, time, urllib.error, urllib.request
from pathlib import Path

base = Path(os.environ["TMPDIR"])
port = int(os.environ["CRAWL4AI_PORT"])
log_path = base / "service.log"
env = os.environ.copy()
env.pop("CRAWL4AI_API_TOKEN", None)
env.pop("REDIS_PASSWORD", None)

with log_path.open("w+") as log:
    proc = subprocess.Popen(
        ["${pkgs.bashNonInteractive}/bin/bash", str(base / "entrypoint.sh")],
        cwd=base, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(f"entrypoint exited early: {proc.returncode}")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
                    body = json.load(response)
                    assert response.status == 200
                    assert body["status"] == "ok"
                    assert body["version"] == "0.9.5"
                break
            except urllib.error.URLError:
                time.sleep(0.5)
        else:
            raise TimeoutError("Crawl4AI health endpoint did not become ready")

        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/openapi.json", timeout=2)
        except urllib.error.HTTPError as error:
            assert error.code == 401
        else:
            raise AssertionError("protected OpenAPI route accepted an unauthenticated request")

        log.flush()
        log.seek(0)
        output = log.read()
        assert "binding loopback only (127.0.0.1:5099)" in output
    except Exception as error:
        log.flush()
        log.seek(0)
        output = log.read()[-8000:]
        output = re.sub(r"(?m)^.*CRAWL4AI_API_TOKEN=.*$", "CRAWL4AI_API_TOKEN=[redacted]", output)
        output = re.sub(r"(?m)^.*REDIS_PASSWORD=.*$", "REDIS_PASSWORD=[redacted]", output)
        raise RuntimeError(f"{error}\n{output}") from error
    finally:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

print("Internal Valkey and Crawl4AI pass /health; unauthenticated API stays loopback-only")
PY
        touch "$out"
      '';

      image = pkgs.dockerTools.buildLayeredImage {
        name = "crawl4ai";
        tag = version;
        contents = [
          pythonEnv
          browsers
          pkgs.dockerTools.fakeNss
          pkgs.cacert
          pkgs.bashNonInteractive
          pkgs.coreutils
          pkgs.valkey
          pkgs.python313Packages.supervisor
          runtimeFiles
        ];

        config = {
          User = "10001:10001";
          WorkingDir = "/app";
          Cmd = [ "${pkgs.bashNonInteractive}/bin/bash" "/app/entrypoint.sh" ];
          Env = [
            "PATH=${pythonEnv}/bin:${pkgs.python313Packages.supervisor}/bin:${pkgs.valkey}/bin:${pkgs.coreutils}/bin:${pkgs.bashNonInteractive}/bin"
            "HOME=/data"
            "TMPDIR=/tmp"
            "PYTHONUNBUFFERED=1"
            "PYTHONDONTWRITEBYTECODE=1"
            "C4AI_VERSION=${version}"
            "REDIS_HOST=127.0.0.1"
            "REDIS_PORT=6379"
            "CRAWL4AI_ARTIFACT_DIR=/data/artifacts"
            "CRAWL4AI_CHROMIUM_SANDBOX=true"
            "PLAYWRIGHT_BROWSERS_PATH=${browsers}"
            "PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1"
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "REQUESTS_CA_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          ];
          ExposedPorts = { "11235/tcp" = { }; };
          Volumes = { "/data" = { }; };
          Healthcheck = {
            Test = [
              "CMD"
              "${pythonEnv}/bin/python"
              "-c"
              "import os,urllib.request; urllib.request.urlopen(f\"http://localhost:{os.getenv('CRAWL4AI_PORT', '11235')}/health\", timeout=2)"
            ];
            Interval = 30 * 1000000000;
            Timeout = 5 * 1000000000;
            StartPeriod = 30 * 1000000000;
            Retries = 3;
          };
          Labels = {
            "org.opencontainers.image.title" = "Crawl4AI";
            "org.opencontainers.image.description" = "Self-hosted Crawl4AI API server";
            "org.opencontainers.image.source" = "https://github.com/unclecode/crawl4ai";
            "org.opencontainers.image.version" = version;
            "org.opencontainers.image.revision" = revision;
            "org.opencontainers.image.licenses" = "Apache-2.0";
            "c4ai.version" = version;
          };
        };

        fakeRootCommands = ''
          mkdir -p ./data/redis ./data/artifacts ./tmp
          chown -R 10001:10001 ./data
          chmod 0700 ./data ./data/redis ./data/artifacts
          chmod 1777 ./tmp
        '';
      };
    in
    {
      packages.${system} = {
        inherit image;
        default = image;
      };

      checks.${system} = {
        inherit image;
        api-import = apiImportCheck;
        browser-sandbox = browserCheck;
        service-health = serviceHealthCheck;
      };
    };
}
