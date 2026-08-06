"""Robot Framework keyword library for mtls-hello Apache/CGI tests."""
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

class MtlsLibrary:
    """Keywords for spinning up the Apache-backed mTLS server and making requests."""
    ROBOT_LIBRARY_SCOPE = "SUITE"

    def __init__(self):
        self._project_root = Path(__file__).parent.parent
        self._cert_dir = None
        self._data_dir = None
        self._apache_bin = None
        self._apache_proc = None
        self._disco_proc = None
        self._port = 18443

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------
    def _run(self, cmd, *, cwd=None, clear_ld=False, timeout=60, **kwargs):
        """Run a subprocess.  clear_ld=True removes LD_LIBRARY_PATH for host binaries."""
        env = os.environ.copy()
        if clear_ld:
            env.pop("LD_LIBRARY_PATH", None)
        return subprocess.run(
            cmd,
            cwd=cwd or self._project_root,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
            **kwargs,
        )

    # ------------------------------------------------------------------
    # keywords
    # ------------------------------------------------------------------
    def set_mtls_port(self, port):
        self._port = int(port)

    def generate_version_file(self):
        """Write source/version_.d from dub.json."""
        import json

        dub_json = self._project_root / "dub.json"
        with open(dub_json) as f:
            data = json.load(f)
        version = data.get("version", "")
        if not version:
            raise AssertionError("could not extract version from dub.json")
        version_file = self._project_root / "source" / "version_.d"
        version_file.write_text(f'module version_;\nenum appVersion = "{version}";\n')

    def build_d_binary(self):
        self.generate_version_file()
        # Nix binaries have rpath entries into the store; keep the environment
        # clean so a stale DC or LD_LIBRARY_PATH from the host cannot confuse dub.
        env = os.environ.copy()
        env.pop("DC", None)
        env.pop("LD_LIBRARY_PATH", None)
        result = subprocess.run(
            ["dub", "build", "--compiler", "ldc2", "--skip-registry", "standard"],
            cwd=self._project_root,
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"dub build failed: rc={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
            )

    def generate_test_certs(self):
        self._cert_dir = Path(tempfile.mkdtemp(prefix="mtls-robot-certs-"))
        for name, cn in [
            ("server", "localhost"),
            ("client", "test-client"),
            ("evil", "evil"),
        ]:
            cmd = [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-keyout",
                str(self._cert_dir / f"{name}.key"),
                "-out",
                str(self._cert_dir / f"{name}.crt"),
                "-subj",
                f"/CN={cn}",
            ]
            if name == "server":
                # curl --cacert needs the server cert to look like a CA that is
                # also valid for server authentication. The full keyUsage lets
                # Apache load it as a server cert while curl still accepts it as
                # the trust anchor.
                cmd.extend([
                    "-addext",
                    "basicConstraints=CA:TRUE",
                    "-addext",
                    "keyUsage=critical,keyCertSign,cRLSign,digitalSignature,keyEncipherment",
                    "-addext",
                    "extendedKeyUsage=serverAuth",
                ])
            else:
                cmd.extend(["-addext", "basicConstraints=CA:FALSE"])
            result = self._run(cmd)
            if result.returncode != 0:
                raise AssertionError(
                    f"openssl failed for {name}: rc={result.returncode}\nstderr={result.stderr}"
                )

    def server_cert(self):
        return str(self._cert_dir / "server.crt")

    def server_key(self):
        return str(self._cert_dir / "server.key")

    def client_cert(self):
        return str(self._cert_dir / "client.crt")

    def client_key(self):
        return str(self._cert_dir / "client.key")

    def evil_cert(self):
        return str(self._cert_dir / "evil.crt")

    def evil_key(self):
        return str(self._cert_dir / "evil.key")

    def detect_apache_binary(self):
        detect_cmd = "PATH=/usr/sbin:$PATH command -v httpd-prefork || command -v httpd || command -v apache2"
        result = self._run(["bash", "-c", detect_cmd], clear_ld=True)
        if result.returncode != 0:
            raise AssertionError(
                f"Apache binary not found: rc={result.returncode}\nstderr={result.stderr}"
            )
        self._apache_bin = result.stdout.strip()

    def create_apache_data_dir(self):
        self._data_dir = Path(tempfile.mkdtemp(prefix="mtls-robot-data-"))
        handlers_dir = self._data_dir / "handlers"
        scripts_dir = self._data_dir / "scripts"
        hosts_dir = self._data_dir / "hosts"
        purgatory_dir = self._data_dir / "purgatory"
        repos_dir = self._data_dir / "repos"
        for d in (handlers_dir, scripts_dir, hosts_dir, purgatory_dir, repos_dir):
            d.mkdir(parents=True)

        for src in (self._project_root / "handlers").glob("*.sh"):
            shutil.copy(src, handlers_dir)
        for src in ("cgi-trust.sh", "cgi-common.sh", "log-capture.sh"):
            shutil.copy(self._project_root / "scripts" / src, scripts_dir)
        shutil.copy(self._cert_dir / "client.crt", hosts_dir / "test-client.crt")

    def generate_apache_config(self):
        result = self._run(
            [
                "bash",
                str(self._project_root / "scripts" / "apache-config.sh"),
                str(self._data_dir),
                str(self._port),
                str(self._cert_dir / "server.crt"),
                str(self._cert_dir / "server.key"),
                str(self._data_dir / "apache" / "httpd.conf"),
            ],
            clear_ld=True,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"apache-config.sh failed: rc={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
            )

    def wait_for_port(self, port=None, timeout=10):
        port = int(port) if port is not None else self._port
        deadline = time.time() + timeout
        while time.time() < deadline:
            result = self._run(
                ["bash", "-c", f"exec 5<>/dev/tcp/127.0.0.1/{port}"],
                clear_ld=True,
                timeout=1,
            )
            if result.returncode == 0:
                return
            time.sleep(0.2)
        raise AssertionError(f"port {port} did not become ready within {timeout}s")

    def start_apache(self):
        self._apache_proc = subprocess.Popen(
            [self._apache_bin, "-f", str(self._data_dir / "apache" / "httpd.conf")],
            env={k: v for k, v in os.environ.items() if k != "LD_LIBRARY_PATH"},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

    def start_discovery(self):
        self._disco_proc = subprocess.Popen(
            [
                str(self._project_root / "mtls-hello"),
                str(self._port),
                "--trust-dir",
                str(self._data_dir / "hosts"),
                "--purgatory-dir",
                str(self._data_dir / "purgatory"),
            ],
            cwd=self._project_root,
            env=os.environ.copy(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

    def setup_test_environment(self):
        self.generate_test_certs()
        self.build_d_binary()
        self.detect_apache_binary()
        self.create_apache_data_dir()
        self.generate_apache_config()
        self.start_apache()
        self.wait_for_port()
        self.start_discovery()

    def teardown_test_environment(self):
        if self._apache_proc is not None:
            try:
                os.killpg(os.getpgid(self._apache_proc.pid), signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self._apache_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(self._apache_proc.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self._apache_proc = None
        if self._disco_proc is not None:
            try:
                os.killpg(os.getpgid(self._disco_proc.pid), signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self._disco_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(self._disco_proc.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self._disco_proc = None
        if self._data_dir is not None:
            self._remove_data_tree(self._data_dir)
            self._data_dir = None
        if self._cert_dir is not None:
            self._remove_data_tree(self._cert_dir)
            self._cert_dir = None

    # ------------------------------------------------------------------
    # safe teardown helpers (no shutil.rmtree — only os.remove/os.rmdir)
    # ------------------------------------------------------------------
    def _remove_data_tree(self, root):
        """Remove a scratch tree we created, removing only the known files and
        directories. Anything left behind is reported, never force-deleted."""
        import os as _os
        root = Path(root)
        if not root.exists():
            return
        # Known files (cert fixtures and runtime files we create).
        known_rel = [
            "server.crt", "server.key", "client.crt", "client.key",
            "evil.crt", "evil.key", "test-client.crt", "test-client.key",
            "httpd.conf", "site.conf", "error.log", "access.log", "httpd.pid",
            "mime/mime.types",
        ]
        for rel in known_rel:
            p = root / rel
            if p.exists() or p.is_symlink():
                p.unlink()
        # Generated capture files: <hostname>.<fingerprint>.crt in purgatory,
        # .crt/.key fixtures, spool .bundle files, and handler/script copies.
        for pat in ("*.crt", "*.key", "*.bundle", "*.sh", "*.py", "*.new"):
            for p in root.glob(pat):
                if p.is_file() or p.is_symlink():
                    p.unlink()
            for sub in ("handlers", "scripts", "hosts", "purgatory", "repos",
                        "apache", "identity"):
                for p in (root / sub).glob(pat):
                    if p.is_file() or p.is_symlink():
                        p.unlink()
        # Known directories, bottom-up.
        known_dirs = [
            "apache/mime", "apache", "handlers", "scripts", "hosts",
            "purgatory", "repos", "identity", "certs/certs", "certs/private",
            "certs",
        ]
        for rel in sorted(known_dirs, key=lambda r: -r.count("/")):
            p = root / rel
            if p.is_dir():
                try:
                    p.rmdir()
                except OSError as exc:
                    print(f"warning: could not rmdir {p}: {exc}", file=sys.stderr)
        if root.is_dir():
            try:
                root.rmdir()
            except OSError as exc:
                print(f"warning: could not rmdir {root}: {exc}", file=sys.stderr)

    # ------------------------------------------------------------------
    # request helpers
    # ------------------------------------------------------------------
    def _curl(self, path, *, cert=None, fail=False, method="GET", data=None):
        cmd = [
            "curl",
            "-sS",
            "--max-time",
            "5",
            "--cacert",
            str(self._cert_dir / "server.crt"),
        ]
        if fail:
            cmd.append("--fail")
        if cert:
            cmd.extend(["--cert", cert[0], "--key", cert[1]])
        if method == "POST" and data is not None:
            cmd.extend(["-X", "POST", "--data-binary", f"@{data}"])
        cmd.append(f"https://localhost:{self._port}{path}")
        return self._run(cmd, timeout=10)

    def mtls_get(self, path):
        result = self._curl(path, cert=(self.client_cert(), self.client_key()), fail=True)
        if result.returncode != 0:
            raise AssertionError(
                f"GET {path} failed: rc={result.returncode}\nstderr={result.stderr}"
            )
        return result.stdout.strip()

    def mtls_get_without_cert(self, path):
        result = self._curl(path, fail=True)
        return result.returncode

    def mtls_get_with_untrusted_cert(self, path):
        result = self._curl(
            path, cert=(self.evil_cert(), self.evil_key()), fail=True
        )
        return result.returncode

    def mtls_get_with_evil_cert(self, path):
        result = self._curl(
            path, cert=(self.evil_cert(), self.evil_key()), fail=True
        )
        if result.returncode != 0:
            raise AssertionError(
                f"GET {path} with evil cert failed: rc={result.returncode}\nstderr={result.stderr}"
            )
        return result.stdout.strip()

    def mtls_post(self, path, data_file):
        result = self._curl(
            path,
            cert=(self.client_cert(), self.client_key()),
            fail=True,
            method="POST",
            data=data_file,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"POST {path} failed: rc={result.returncode}\nstderr={result.stderr}"
            )
        return result.stdout.strip()

    def remove_all_purgatory_files(self):
        purgatory = self._data_dir / "purgatory"
        if purgatory.exists():
            self._remove_data_tree(purgatory)
        purgatory.mkdir()

    def list_purgatory_files(self):
        purgatory = self._data_dir / "purgatory"
        return [f.name for f in purgatory.iterdir() if f.is_file()]

    def wait_for_purgatory_file(self, timeout=3.0):
        # Capture is now asynchronous (piped logger writes after the response),
        # so poll briefly for the file to appear.
        import time as _time
        deadline = _time.time() + float(timeout)
        files = self.list_purgatory_files()
        while not files and _time.time() < deadline:
            _time.sleep(0.1)
            files = self.list_purgatory_files()
        return files

    def promote_captured_cert(self):
        files = self.wait_for_purgatory_file()
        if len(files) != 1:
            raise AssertionError(f"expected exactly one purgatory file, got {files}")
        shutil.copy(
            self._data_dir / "purgatory" / files[0],
            self._data_dir / "hosts" / "evil.crt",
        )
        (self._data_dir / "hosts" / "test-client.crt").unlink(missing_ok=True)
