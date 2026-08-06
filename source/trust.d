/// Trust-by-hostname verification for inbound client certificates.
///
/// A peer is trusted only when its certificate is present in the local trust
/// store under the peer's hostname (derived from the certificate's common
/// name) and the presented certificate matches the stored one by SHA-256
/// fingerprint. Unknown or mismatched certificates are captured into a
/// purgatory directory for operator review; capture does not grant trust.
module trust;

import vibe.core.log;
import vibe.core.net : connectTCP;
import vibe.stream.openssl;
import vibe.stream.tls;

import deimos.openssl.bio;
import deimos.openssl.evp;
import deimos.openssl.pem;
import deimos.openssl.x509;

import std.datetime : seconds;
import std.digest.sha;
import std.file;
import std.format;
import std.path;
import std.string;
import std.uni : toLower;

struct TrustConfig
{
	string trustDir = "hosts";
	string purgatoryDir = "purgatory";
	bool trustDirExplicit;
	bool purgatoryDirExplicit;
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

struct PeerCertificateCapture
{
	string hostname;
	string fingerprint;
	string pem;
	string purgatoryPath;
}

/// Detect and capture the certificate presented by a peer during an outbound
/// mTLS connection. The captured certificate is stored in purgatory keyed by
/// hostname and fingerprint, which makes repeated captures idempotent.
/// Returns the capture result; purgatoryPath is empty on failure or when the
/// certificate has no usable hostname.
PeerCertificateCapture detectPeerCertificate(string peerHost, ushort peerPort,
	string ourCert, string ourKey, string purgatoryDir) @trusted
{
	auto result = PeerCertificateCapture();
	if (peerHost.empty || ourCert.empty || ourKey.empty || purgatoryDir.empty)
		return result;

	try
	{
		auto conn = connectTCP(peerHost, peerPort, null, 0, 5.seconds);
		auto ctx = createTLSContext(TLSContextKind.client);
		ctx.useCertificateChainFile(ourCert);
		ctx.usePrivateKeyFile(ourKey);
		ctx.peerValidationMode = TLSPeerValidationMode.requireCert;

		auto stream = createTLSStream(conn, ctx);
		auto certInfo = stream.peerCertificate;

		result.hostname = hostnameFromCertificate(certInfo);
		if (result.hostname.empty)
			return result;

		result.pem = x509ToPEM(certInfo._x509);
		if (result.pem.empty)
			return result;

		result.fingerprint = x509Fingerprint(certInfo._x509);
		if (result.fingerprint.empty)
			return result;

		result.purgatoryPath = capturePurgatory(purgatoryDir, result.hostname,
			result.pem, result.fingerprint);
	}
	catch (Exception e)
	{
		logWarn("trust: failed to detect peer certificate from %s:%d: %s",
			peerHost, peerPort, e.msg);
	}

	return result;
}

/// Public wrapper for purgatory capture that documents the idempotent
/// deduplication contract. Same hostname + fingerprint always yields the
/// same filesystem path; repeated calls overwrite the same file.
string captureOrFindPurgatory(string purgatoryDir, string hostname, string pem, string fingerprint) @trusted
{
	return capturePurgatory(purgatoryDir, hostname, pem, fingerprint);
}

private void safeRmdirRecurse(string path) nothrow
{
	try { rmdirRecurse(path); } catch (Exception) {}
}

unittest
{
	import std.file : exists, readText, tempDir;
	import std.path : buildPath;

	auto purgDir = buildPath(tempDir(), "mtls-purgatory-test");
	scope (exit) safeRmdirRecurse(purgDir);

	string pem = "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n";
	string fp = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

	auto path = captureOrFindPurgatory(purgDir, "testhost", pem, fp);
	assert(path.length > 0, "capture path should not be empty");
	assert(exists(path), "capture path should exist");
	assert(readText(path) == pem, "captured PEM should match");

	// Second capture with the same hostname and fingerprint must return the
	// same path and must not create a duplicate file.
	auto path2 = captureOrFindPurgatory(purgDir, "testhost", pem, fp);
	assert(path2 == path, "same fingerprint must not create a duplicate file");
}

unittest
{
	import vibe.stream.tls : TLSCertificateInformation;

	auto certInfo = TLSCertificateInformation();
	certInfo.subjectName.addField("commonName", "unittest-host");
	assert(hostnameFromCertificate(certInfo) == "unittest-host");
}

unittest
{
	import std.file : exists, readText, tempDir, write;
	import std.path : buildPath;
	import std.process : executeShell;
	import std.string : indexOf;

	auto dir = buildPath(tempDir(), "mtls-cert-test");
	scope (exit) safeRmdirRecurse(dir);
	mkdirRecurse(dir);

	auto keyPath = buildPath(dir, "key.pem");
	auto certPath = buildPath(dir, "cert.pem");

	auto res = executeShell(
		"openssl req -x509 -newkey rsa:2048 -nodes -days 1 " ~
		"-keyout '" ~ keyPath ~ "' -out '" ~ certPath ~ "' -subj '/CN=unittest-host' >/dev/null 2>&1");
	assert(res.status == 0, "openssl cert generation failed: " ~ res.output);

	auto pem = readText(certPath);
	auto cert = pemToX509(pem);
	assert(cert !is null, "pemToX509 should parse the generated cert");
	scope (exit)
	{
		import deimos.openssl.x509 : X509_free;
		X509_free(cert);
	}

	string fp = x509Fingerprint(cert);
	assert(fp.length == 64, "fingerprint should be 64 hex chars");

	string pem2 = x509ToPEM(cert);
	assert(pem2.length > 0, "x509ToPEM should produce PEM");
	assert(pem2.indexOf("BEGIN CERTIFICATE") >= 0, "PEM should contain certificate header");
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
