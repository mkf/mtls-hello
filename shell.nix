# mtls-hello development shell — plain Nix, no flakes.
#
#   nix-shell                # enter the shell
#   nix-shell --run "just build"
#
# Uses Nixpkgs to provide a real OpenSSL 3.x toolchain and the LDC/Dub stack
# without relying on the host's LibreSSL.

{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = [
    pkgs.ldc              # LDC D compiler (provides ldc2)
    pkgs.dub              # D package manager
    pkgs.openssl          # OpenSSL 3.x (host has LibreSSL)
    pkgs.pkg-config
    pkgs.curl
    pkgs.bash
    pkgs.git
    pkgs.cacert           # CA bundle so HTTPS/dub registry works
    pkgs.bats             # legacy BATS end-to-end tests
    pkgs.patchelf         # rpath rewriting for self-extracting installer / packaging
    (pkgs.python3.withPackages (ps: [ ps.robotframework ]))
  ];

  shellHook = ''
    # Ensure dub can talk to the registry and curl uses the CA bundle.
    export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
  '';
}
