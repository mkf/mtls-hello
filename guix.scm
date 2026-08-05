;; Development environment for mtls-hello (D + vibe.d mutual-TLS server).
;;
;;   guix shell -f guix.scm          # enter the shell
;;   guix shell -f guix.scm -- dub build --compiler=ldc2
;;
;; Uses LDC because Guix's `dmd` is GNU Shepherd, not the D compiler.
(use-modules (gnu packages))

(list
  ;; D toolchain (LDC frontend 2.097; dub)
  (specification->package "dub")
  (specification->package "ldc")
  ;; C toolchain used for linking
  (specification->package "gcc-toolchain")
  ;; real OpenSSL 3.x — the host's /usr/lib64 ships LibreSSL which is
  ;; ABI-incompatible with the deimos OpenSSL bindings used by vibe-d
  (specification->package "openssl")
  (specification->package "pkg-config")
  ;; testing / cert tooling
  (specification->package "curl")
  (specification->package "bats")
  ;; git — used by the multi-repo sync demo BATS test
  (specification->package "git")
  ;; CA bundle so HTTPS (dub registry, curl) works inside the shell
  (specification->package "nss-certs")
  ;; runtime + link dependency pulled in by the OpenSSL stack
  (specification->package "zlib")
  ;; patchelf — rewrite the binary's interpreter and rpath so the
  ;; self-extracting installer works on non-Guix targets
  (specification->package "patchelf"))
