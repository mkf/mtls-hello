/// Mutual-TLS hello: `GET /:whatever` -> `$whatever` as text/plain.
///
/// Usage: mtls-hello [port] [serverCert] [serverKey] [options]
/// Positional defaults: 8443 ~/.local/share/mtls-hello/certs/certs/server.crt ~/.local/share/mtls-hello/certs/private/server.key
/// Options:
///   --version                Print version and exit
///   --port=0                 Listen port (0 = random ephemeral port)
///   --port-file=PATH         Write the chosen port number to PATH
///   --multicast-group=239.255.42.42
///   --multicast-port=4242
///   --multicast-interval=5   (seconds)
///   --no-multicast
///   --handlers-dir=DIR       (default: handlers)
///   --script-timeout=SECS    (default: 10, min 1)
///
/// Environment variables used by multicast discovery and the sync callback:
///   HOST_NAME                Hostname advertised to peers (default: system hostname)
///   CALLBACK_SCRIPT          Path to on-discover.sh (default: $HOME/.local/share/mtls-hello/scripts/on-discover.sh)
///   OUR_CERT                 Client certificate for outgoing mTLS sync calls
///   OUR_KEY                  Client key for outgoing mTLS sync calls
///   REPOS_ROOT               Directory containing bare git repositories to sync
module app;

import vibe.core.core;
import vibe.core.log;
import vibe.http.common : HTTPMethod, HTTPStatus;
import vibe.http.router;
import vibe.http.server;
import vibe.stream.openssl;
import vibe.stream.operations : readAll;
import vibe.stream.tls;

import handlers;
import multicast;
import trust;

import std.conv : to;
import std.datetime : Duration, seconds;
import std.file : mkdirRecurse, rename, write;
import std.path : dirName, expandTilde;
import std.process : environment;
import std.socket : InternetAddress, Socket, AddressFamily, SocketType;
import std.stdio : SEEK_SET, writeln;
import std.string : empty, join, startsWith;

import version_ : appVersion;

struct ServerConfig
{
	ushort port = 8443;
	string certFile = "~/.local/share/mtls-hello/certs/certs/server.crt";
	string keyFile = "~/.local/share/mtls-hello/certs/private/server.key";
	string portFile;
	/// Base directory for runtime data (handlers, scripts, future).
	string dataDir;
	bool handlersExplicit;
	MulticastConfig multicast;
	HandlerConfig handlers;
	TrustConfig trust;
}

void main(string[] args)
{
	foreach (arg; args)
		if (arg == "--version")
		{
			writeln(appVersion);
			return;
		}

	auto cfg = parseArgs(args);
	// Default to the system hostname so peers can identify us uniquely.
	// The operator can override with HOST_NAME env var.
	import std.socket : Socket;
	cfg.multicast.hostName = environment.get("HOST_NAME", Socket.hostName);
	cfg.multicast.callbackScript = environment.get("CALLBACK_SCRIPT", "");
	cfg.multicast.trustDir = cfg.trust.trustDir;

	// Derive sub-paths from data directory unless explicitly overridden.
	if (cfg.dataDir.length > 0)
	{
		if (!cfg.handlersExplicit)
			cfg.handlers.handlersDir = cfg.dataDir ~ "/handlers";
		if (cfg.multicast.callbackScript.length == 0)
			cfg.multicast.callbackScript = cfg.dataDir ~ "/scripts/on-discover.sh";
		cfg.trust.trustDir = cfg.dataDir ~ "/hosts";
		cfg.trust.purgatoryDir = cfg.dataDir ~ "/purgatory";
	}

	if (cfg.port == 0)
		cfg.port = findRandomPort();

	auto tls = buildTLSContext(cfg);
	auto router = buildRouter(cfg);
	auto settings = buildServerSettings(cfg.port, tls);

	if (!cfg.portFile.empty)
		writePortFile(cfg.portFile, cfg.port);

	logInfo("listening on https://%s:%s (mutual TLS, client certs verified by trust store %s)",
		settings.bindAddresses.join(", "), cfg.port, cfg.trust.trustDir);
	logInfo("purgatory directory: %s", cfg.trust.purgatoryDir);

	if (cfg.multicast.enabled)
		logInfo("multicast discovery on %s:%d (interval %s)",
			cfg.multicast.group, cfg.multicast.port, cfg.multicast.interval);

	logInfo("handlers directory: %s (script timeout: %s)",
		cfg.handlers.handlersDir, cfg.handlers.scriptTimeout);

	listenHTTP(settings, (scope HTTPServerRequest req, scope HTTPServerResponse res) {
		auto decision = evaluateTrust(req, cfg.trust);
		logTrustDecision(decision);
		if (decision.outcome != TrustOutcome.trusted)
		{
			res.statusCode = HTTPStatus.unauthorized;
			res.writeBody("Untrusted");
			return;
		}
		router.handleRequest(req, res);
	});
	startMulticastDiscovery(cfg.port, cfg.multicast);
	runEventLoop();
}

/// Parse positional arguments and optional flags. Positional values are read
/// first; everything after the first `--` token is treated as a flag.
private ServerConfig parseArgs(string[] args)
{
	ServerConfig cfg;
	cfg.multicast.enabled = true;
	cfg.multicast.group = "239.255.42.42";
	cfg.multicast.port = 4242;
	cfg.multicast.interval = 5.seconds;

	size_t i = 1;
	for (; i < args.length && !args[i].startsWith("--"); i++)
	{
		switch (i)
		{
			case 1: cfg.port = args[i].to!ushort; break;
			case 2: cfg.certFile = args[i]; break;
			case 3: cfg.keyFile = args[i]; break;
			default: break;
		}
	}

	for (; i < args.length; i++)
	{
		auto a = args[i];
		if (a == "--no-multicast")
			cfg.multicast.enabled = false;
		else if (a == "--port-file")
		{
			if (i + 1 >= args.length || args[i + 1].startsWith("--"))
				throw new Exception("--port-file requires a value");
			cfg.portFile = args[++i];
		}
		else if (a.startsWith("--port-file="))
			cfg.portFile = a["--port-file=".length .. $];
		else if (a.startsWith("--multicast-group="))
			cfg.multicast.group = a["--multicast-group=".length .. $];
		else if (a.startsWith("--multicast-port="))
			cfg.multicast.port = a["--multicast-port=".length .. $].to!ushort;
		else if (a.startsWith("--multicast-interval="))
			cfg.multicast.interval = a["--multicast-interval=".length .. $].to!int.seconds;
		else if (a == "--data-dir")
		{
			if (i + 1 >= args.length || args[i + 1].startsWith("--"))
				throw new Exception("--data-dir requires a value");
			cfg.dataDir = args[++i];
		}
		else if (a.startsWith("--data-dir="))
			cfg.dataDir = a["--data-dir=".length .. $];
		else if (a == "--handlers-dir")
		{
			if (i + 1 >= args.length || args[i + 1].startsWith("--"))
				throw new Exception("--handlers-dir requires a value");
			cfg.handlers.handlersDir = args[++i];
			cfg.handlersExplicit = true;
		}
		else if (a.startsWith("--handlers-dir="))
		{
			cfg.handlers.handlersDir = a["--handlers-dir=".length .. $];
			cfg.handlersExplicit = true;
		}
		else if (a == "--trust-dir")
		{
			if (i + 1 >= args.length || args[i + 1].startsWith("--"))
				throw new Exception("--trust-dir requires a value");
			cfg.trust.trustDir = args[++i];
		}
		else if (a.startsWith("--trust-dir="))
			cfg.trust.trustDir = a["--trust-dir=".length .. $];
		else if (a == "--purgatory-dir")
		{
			if (i + 1 >= args.length || args[i + 1].startsWith("--"))
				throw new Exception("--purgatory-dir requires a value");
			cfg.trust.purgatoryDir = args[++i];
		}
		else if (a.startsWith("--purgatory-dir="))
			cfg.trust.purgatoryDir = a["--purgatory-dir=".length .. $];
		else if (a == "--script-timeout")
		{
			if (i + 1 >= args.length || args[i + 1].startsWith("--"))
				throw new Exception("--script-timeout requires a value");
			auto secs = args[++i].to!int;
			if (secs < 1)
				throw new Exception("--script-timeout must be at least 1 second");
			cfg.handlers.scriptTimeout = secs.seconds;
		}
		else if (a.startsWith("--script-timeout="))
		{
			auto secs = a["--script-timeout=".length .. $].to!int;
			if (secs < 1)
				throw new Exception("--script-timeout must be at least 1 second");
			cfg.handlers.scriptTimeout = secs.seconds;
		}
	}

	return cfg;
}

/// Build the server-side mutual-TLS context. A client certificate is required
/// but not verified at the TLS layer; trust is decided per-hostname by the
/// application-layer trust store.
private OpenSSLContext buildTLSContext(ref const(ServerConfig) cfg)
{
	auto tls = new OpenSSLContext(TLSContextKind.server);
	tls.useCertificateChainFile(cfg.certFile.expandTilde);
	tls.usePrivateKeyFile(cfg.keyFile.expandTilde);
	// Require a client certificate, but do not verify it against a CA pool.
	// Trust is decided per-hostname by the application-layer trust store. The
	// certificate's validity dates and hostname are checked when it is evaluated.
	tls.peerValidationMode = TLSPeerValidationMode.requireCert;
	return tls;
}

/// Build the HTTP router. GET /:name and POST /:name dispatch to handler
/// scripts when present; otherwise GET falls back to the echo behavior and
/// POST returns 404.
private URLRouter buildRouter(ref const(ServerConfig) cfg)
{
	auto router = new URLRouter;

	void handleScript(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		try
		{
			string name = req.params.get("name", "");

			if (!isValidName(name))
			{
				res.statusCode = HTTPStatus.badRequest;
				res.writeBody("Invalid handler name");
				return;
			}

			string method = req.method == HTTPMethod.POST ? "post" : "get";
			auto scriptPath = resolveScript(cfg.handlers, method, name);

			if (scriptPath is null)
			{
				if (req.method == HTTPMethod.GET)
				{
					res.writeBody(name, "text/plain; charset=utf-8");
					return;
				}
				else
				{
					res.statusCode = HTTPStatus.notFound;
					res.writeBody("Not found");
					return;
				}
			}

			ubyte[] body;
			if (req.method == HTTPMethod.POST)
				body = req.bodyReader.readAll();

			auto env = buildEnv(req);
			auto result = executeScript(cfg.handlers, scriptPath, env, body);

			if (result.timedOut || result.exitCode != 0)
			{
				logWarn("handler %s failed: timedOut=%s exitCode=%d stderr='%s'",
					scriptPath, result.timedOut, result.exitCode, result.stderr);
				res.statusCode = HTTPStatus.internalServerError;
				res.writeBody("Internal Server Error");
				return;
			}

			res.writeBody(result.stdout, "text/plain; charset=utf-8");
		}
		catch (Exception e)
		{
			logWarn("handler dispatch threw: %s", e.toString);
			res.statusCode = HTTPStatus.internalServerError;
			res.writeBody("Internal Server Error");
		}
	}

	router.get("/:name", &handleScript);
	router.post("/:name", &handleScript);
	return router;
}

/// Build the HTTP server settings: bind on all interfaces so peers on the LAN
/// can reach the server (the multicast discovery feature assumes LAN
/// reachability), use the supplied TLS context, and serve on the configured
/// port.
private HTTPServerSettings buildServerSettings(ushort port, OpenSSLContext tls)
{
	auto settings = new HTTPServerSettings;
	settings.port = port;
	settings.bindAddresses = ["::"];
	settings.tlsContext = tls;
	settings.maxRequestSize = 100_000_000; // 100MB for git bundles
	return settings;
}

/// Pre-bind a temporary socket to port 0 and return the OS-assigned ephemeral
/// port. This is the portable way to ask the kernel for a free port.
private ushort findRandomPort()
{
	auto socket = new Socket(AddressFamily.INET, SocketType.STREAM);
	scope (exit) socket.close();
	socket.bind(new InternetAddress(0));
	auto ia = cast(InternetAddress) socket.localAddress();
	assert(ia !is null, "Socket did not bind to an IPv4 address");
	return ia.port;
}

/// Atomically write the chosen port number to a file. The content is just the
/// decimal port (no newline). The write is done via a temp-file + rename so
/// observers never see partial content.
private void writePortFile(string path, ushort port)
{
	import std.format : format;
	try
	{
		mkdirRecurse(dirName(path));
		auto tmp = path ~ ".tmp";
		write(tmp, format("%d", port));
		rename(tmp, path);
	}
	catch (Exception e)
	{
		logWarn("Failed to write port file %s: %s", path, e.toString());
	}
}
