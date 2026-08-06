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
        drop_dir = self._data_dir / "drop"
        for d in (handlers_dir, scripts_dir, hosts_dir, purgatory_dir, repos_dir, drop_dir):
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
            "purgatory", "repos", "identity", "drop",
            "certs/certs", "certs/private",
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

    # ==================================================================
    # Drop-box keywords (feature 023)
    # ==================================================================

    def generate_alternate_identities(self, identities):
        """Generate one or more alternate self-signed identities.
        Each item is (name, cn)."""
        for name, cn in identities:
            cmd = [
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-days", "1",
                "-keyout", str(self._cert_dir / f"{name}.key"),
                "-out", str(self._cert_dir / f"{name}.crt"),
                "-subj", f"/CN={cn}",
            ]
            result = self._run(cmd)
            if result.returncode != 0:
                raise AssertionError(f"openssl failed for {name}: {result.stderr}")

    def trust_identity(self, name):
        """Copy <name>.crt into <data-dir>/hosts/<cn>.crt."""
        cert_file = self._cert_dir / f"{name}.crt"
        result = self._run(
            ["openssl", "x509", "-in", str(cert_file), "-noout",
             "-subject", "-nameopt", "RFC2253"]
        )
        cn = ""
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith("subject="):
                rest = line[len("subject="):]
                for tag in ("CN = ", "CN=", "CN="):
                    pos = rest.find(tag)
                    if pos != -1:
                        cn = rest[pos + len(tag):]
                        for sep in (",",):
                            ci = cn.find(sep)
                            if ci != -1:
                                cn = cn[:ci]
                        cn = cn.strip()
                        break
                break
        if not cn:
            raise AssertionError(f"could not extract CN from {cert_file}")
        shutil.copy(cert_file, self._data_dir / "hosts" / f"{cn}.crt")

    def trust_two_identities(self):
        """Generate alice + bob and trust both."""
        self.generate_alternate_identities(
            [("alice", "alice.test"), ("bob", "bob.test")]
        )
        self.trust_identity("alice")
        self.trust_identity("bob")

    def cert_for(self, name):
        return str(self._cert_dir / f"{name}.crt")

    def key_for(self, name):
        return str(self._cert_dir / f"{name}.key")

    def _curl_full(self, path, *, method="GET", cert=None, body_file=None,
                   extra_headers=None, timeout=10):
        """Make a curl request; return (status, headers_dict, body_bytes)."""
        import tempfile as _t
        hf, hp = _t.mkstemp(prefix="mtlsh-h-", dir=self._cert_dir)
        os.close(hf)
        bf, bp = _t.mkstemp(prefix="mtlsh-b-", dir=self._cert_dir)
        os.close(bf)
        cmd = ["curl", "-sS", "--max-time", str(timeout),
               "--cacert", str(self._cert_dir / "server.crt"),
               "-X", method, "-D", hp, "-o", bp, "-w", "%{http_code}"]
        if cert:
            cmd.extend(["--cert", cert[0], "--key", cert[1]])
        if body_file:
            cmd.extend(["--data-binary", f"@{body_file}"])
        if extra_headers:
            for k, v in extra_headers.items():
                cmd.extend(["--header", f"{k}: {v}"])
        cmd.append(f"https://localhost:{self._port}{path}")
        result = self._run(cmd, timeout=timeout + 2)
        try:
            status = int(result.stdout.strip() or -1)
        except ValueError:
            status = -1
        headers = {}
        try:
            with open(hp, "r", errors="replace") as f:
                for line in f:
                    if ":" not in line or line.startswith("HTTP/"):
                        continue
                    k, _, v = line.partition(":")
                    k = k.strip().lower()
                    v = v.strip().rstrip("\r")
                    headers[k] = v
        except OSError:
            pass
        finally:
            try: os.unlink(hp)
            except OSError: pass
        body = b""
        try:
            with open(bp, "rb") as f:
                body = f.read()
        except OSError:
            pass
        finally:
            try: os.unlink(bp)
            except OSError: pass
        return status, headers, body

    def mtls_drop(self, remote, source_file, identity="client"):
        """PUT a file to /drop/<cn>/<remote>."""
        c = self._identity_cert(identity)
        path = f"/drop/{self._identity_cn(identity)}/{remote.lstrip('/')}"
        s, h, b = self._curl_full(path, method="PUT", cert=c, body_file=source_file)
        return s

    def mtls_drop_body(self, remote, body_bytes, identity="client"):
        """PUT raw bytes to /drop/<cn>/<remote>."""
        import tempfile as _t
        f, p = _t.mkstemp(prefix="mtlsh-put-", dir=self._cert_dir)
        os.write(f, body_bytes)
        os.close(f)
        try:
            return self.mtls_drop(remote, p, identity)
        finally:
            try: os.unlink(p)
            except OSError: pass

    def mtls_get_drop(self, remote, identity="client", headers=None):
        """GET /drop/<cn>/<remote>; return (status, body_bytes)."""
        c = self._identity_cert(identity)
        path = f"/drop/{self._identity_cn(identity)}/{remote.lstrip('/')}"
        return self._curl_full(path, method="GET", cert=c, extra_headers=headers)

    def mtls_get_drop_status(self, remote, identity="client"):
        return self.mtls_get_drop(remote, identity)[0]

    def mtls_head_drop(self, remote, identity="client"):
        c = self._identity_cert(identity)
        path = f"/drop/{self._identity_cn(identity)}/{remote.lstrip('/')}"
        return self._curl_full(path, method="HEAD", cert=c)

    def mtls_delete_drop(self, remote, identity="client", headers=None):
        c = self._identity_cert(identity)
        path = f"/drop/{self._identity_cn(identity)}/{remote.lstrip('/')}"
        return self._curl_full(path, method="DELETE", cert=c, extra_headers=headers)[0]

    def mtls_mkcol_drop(self, remote, identity="client"):
        c = self._identity_cert(identity)
        path = f"/drop/{self._identity_cn(identity)}/{remote.lstrip('/')}"
        return self._curl_full(path, method="MKCOL", cert=c)[0]

    def mtls_copy_drop(self, src, dest, identity="client", overwrite=False):
        c = self._identity_cert(identity)
        cn = self._identity_cn(identity)
        path = f"/drop/{cn}/{src.lstrip('/')}"
        hdrs = {"Destination": f"/drop/{cn}/{dest.lstrip('/')}"}
        if overwrite:
            hdrs["Overwrite"] = "T"
        return self._curl_full(path, method="COPY", cert=c, extra_headers=hdrs)[0]

    def mtls_move_drop(self, src, dest, identity="client", overwrite=False):
        c = self._identity_cert(identity)
        cn = self._identity_cn(identity)
        path = f"/drop/{cn}/{src.lstrip('/')}"
        hdrs = {"Destination": f"/drop/{cn}/{dest.lstrip('/')}"}
        if overwrite:
            hdrs["Overwrite"] = "T"
        return self._curl_full(path, method="MOVE", cert=c, extra_headers=hdrs)[0]

    def mtls_propfind_drop(self, remote="", depth=0, identity="client"):
        c = self._identity_cert(identity)
        cn = self._identity_cn(identity)
        path = f"/drop/{cn}/{remote.lstrip('/')}"
        return self._curl_full(path, method="PROPFIND", cert=c,
                               extra_headers={"Depth": str(depth)})

    def _identity_cert(self, name):
        """Return (cert_path, key_path) for a named identity."""
        if name == "client":
            return (self.client_cert(), self.client_key())
        elif name == "evil":
            return (self.evil_cert(), self.evil_key())
        return (self.cert_for(name), self.key_for(name))

    def _identity_cn(self, name):
        """Return the CN for a named identity."""
        if name == "client":
            return "test-client"
        elif name == "evil":
            return "evil"
        # Extract CN from the cert.
        result = self._run([
            "openssl", "x509", "-in", self.cert_for(name), "-noout",
            "-subject", "-nameopt", "RFC2253"
        ])
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith("subject="):
                for tag in ("CN = ", "CN=", "CN="):
                    pos = line.find(tag)
                    if pos != -1:
                        cn = line[pos + len(tag):]
                        for sep in (",",):
                            ci = cn.find(sep)
                            if ci != -1:
                                cn = cn[:ci]
                        return cn.strip()
        return name

    def mtls_get_drop_cross_host(self, url_cn, remote, identity="alice"):
        """GET /drop/<url_cn>/<remote> using identity's cert.
        Used to test cross-host 403 rejection."""
        c = self._identity_cert(identity)
        path = f"/drop/{url_cn}/{remote.lstrip('/')}"
        return self._curl_full(path, method="GET", cert=c)
