/// Trust-by-hostname verification for inbound client certificates.
///
/// A peer is trusted only when its certificate is present in the local trust
/// store under the peer's hostname (derived from the certificate's common
/// name) and the presented certificate matches the stored one by SHA-256
/// fingerprint. Unknown or mismatched certificates are captured into a
/// purgatory directory for operator review; capture does not grant trust.
module trust;

import vibe.core.log;
import vibe.http.server;
import vibe.stream.tls;

import deimos.openssl.bio;
import deimos.openssl.evp;
import deimos.openssl.pem;
import deimos.openssl.x509;

import std.digest.sha;
import std.file;
import std.format;
import std.path;
import std.string;
import std.uni : toLower;

struct TrustConfig
{
	string trustDir = "certs/hosts";
	string purgatoryDir = "certs/purgatory";
}

enum TrustOutcome
{
	trusted,
	unknown,
	mismatch,
	expired,
	invalidName
}

struct TrustDecision
{
	TrustOutcome outcome;
	string hostname;
	string fingerprint;
	string trustPath;
	string purgatoryPath;
}

/// Decide whether a peer is trusted. This runs inside the request handler;
/// the client certificate is only valid for the lifetime of the TLS stream, so
/// the fingerprint/PEM are extracted eagerly here.
TrustDecision evaluateTrust(scope HTTPServerRequest req, ref const(TrustConfig) cfg) @trusted
{
	auto certInfo = req.clientCertificate;
	string hostname = hostnameFromCertificate(certInfo);

	if (hostname.empty)
		return TrustDecision(TrustOutcome.invalidName, "", "");

	string pem = x509ToPEM(certInfo._x509);
	if (pem.empty)
		return TrustDecision(TrustOutcome.unknown, hostname, "");

	string fingerprint = x509Fingerprint(certInfo._x509);
	if (fingerprint.empty)
		return TrustDecision(TrustOutcome.unknown, hostname, "");

	string trustPath = buildPath(cfg.trustDir, hostname ~ ".crt");
	if (exists(trustPath))
	{
		string storedFingerprint = loadTrustedCertFingerprint(trustPath);
		if (storedFingerprint == fingerprint)
			return TrustDecision(TrustOutcome.trusted, hostname, fingerprint, trustPath);
		else
		{
			auto decision = TrustDecision(TrustOutcome.mismatch, hostname, fingerprint, trustPath);
			decision.purgatoryPath = capturePurgatory(cfg.purgatoryDir, hostname, pem, fingerprint);
			return decision;
		}
	}

	auto decision = TrustDecision(TrustOutcome.unknown, hostname, fingerprint, trustPath);
	decision.purgatoryPath = capturePurgatory(cfg.purgatoryDir, hostname, pem, fingerprint);
	return decision;
}

/// Log a trust decision with hostname, fingerprint, and reason. For unknown or
/// mismatched peers, also log the purgatory path so the operator can review.
void logTrustDecision(ref const(TrustDecision) decision) @safe
{
	final switch (decision.outcome)
	{
		case TrustOutcome.trusted:
			logInfo("trust: trusted hostname=%s fingerprint=%s", decision.hostname, decision.fingerprint);
			break;
		case TrustOutcome.unknown:
			logWarn("trust: unknown hostname=%s fingerprint=%s purgatory=%s",
				decision.hostname, decision.fingerprint, decision.purgatoryPath);
			break;
		case TrustOutcome.mismatch:
			logWarn("trust: mismatch hostname=%s fingerprint=%s trustPath=%s purgatory=%s",
				decision.hostname, decision.fingerprint, decision.trustPath, decision.purgatoryPath);
			break;
		case TrustOutcome.expired:
			logWarn("trust: expired hostname=%s fingerprint=%s", decision.hostname, decision.fingerprint);
			break;
		case TrustOutcome.invalidName:
			logWarn("trust: invalid-name (no usable hostname)");
			break;
	}
}

/// Extract the hostname from the certificate's subject name. The common name
/// (CN) is the primary source; if no CN is present, no hostname is derived.
private string hostnameFromCertificate(ref const(TLSCertificateInformation) certInfo) @trusted
{
	// The DictionaryList exposes a `get` lookup for single-valued fields.
	string cn = certInfo.subjectName.get("commonName", "");
	if (!cn.empty)
		return cn;

	foreach (key, value; certInfo.subjectName.byKeyValue)
	{
		if (key.toLower == "commonname" || key.toLower == "cn")
			return value;
	}

	return "";
}

/// Convert an in-memory X509 pointer to a PEM string. Returns empty on error.
private string x509ToPEM(void* x509) @trusted
{
	if (x509 is null)
		return "";

	X509* cert = cast(X509*) x509;
	BIO* bio = BIO_new(BIO_s_mem());
	if (bio is null)
		return "";
	scope (exit)
		BIO_free(bio);

	if (!PEM_write_bio_X509(bio, cert))
		return "";

	char[8192] buf;
	int n = BIO_read(bio, buf.ptr, cast(int) buf.length);
	if (n <= 0)
		return "";

	return buf[0 .. n].idup;
}

/// Compute the SHA-256 fingerprint of an in-memory X509 pointer. Returns
/// empty on error.
private string x509Fingerprint(void* x509) @trusted
{
	if (x509 is null)
		return "";

	X509* cert = cast(X509*) x509;
	ubyte[32] md;
	uint len = md.length;

	if (!X509_digest(cert, EVP_sha256(), md.ptr, &len))
		return "";

	return format("%(%02x%)", md[0 .. len]);
}

/// Parse a PEM file and return its SHA-256 fingerprint. Returns empty if the
/// file is missing or unreadable.
private string loadTrustedCertFingerprint(string path) @trusted
{
	if (!exists(path))
		return "";

	try
	{
		string pem = readText(path);
		X509* cert = pemToX509(pem);
		if (cert is null)
			return "";
		scope (exit)
			X509_free(cert);
		return x509Fingerprint(cert);
	}
	catch (Exception)
	{
		return "";
	}
}

/// Parse a PEM string into an X509 pointer. The caller must free the result.
private X509* pemToX509(string pem) @trusted
{
	if (pem.empty)
		return null;

	BIO* bio = BIO_new_mem_buf(cast(void*) pem.ptr, cast(int) pem.length);
	if (bio is null)
		return null;
	scope (exit)
		BIO_free(bio);

	X509* cert = null;
	cert = PEM_read_bio_X509(bio, &cert, null, null);
	return cert;
}

/// Capture a rejected certificate into purgatory. The filename is keyed by
/// hostname and fingerprint so repeated captures are idempotent (overwrite).
/// Returns the path written, or empty on failure.
private string capturePurgatory(string purgatoryDir, string hostname, string pem, string fingerprint) @trusted
{
	if (purgatoryDir.empty || hostname.empty || fingerprint.empty)
		return "";

	try
	{
		mkdirRecurse(purgatoryDir);
		string path = buildPath(purgatoryDir, format("%s.%s.crt", hostname, fingerprint));
		write(path, pem);
		return path;
	}
	catch (Exception)
	{
		return "";
	}
}
