/// mTLS-hello discovery daemon.
///
/// Apache httpd serves the HTTPS endpoints and runs the CGI handlers.
/// This binary is responsible only for LAN multicast discovery and outbound
/// peer certificate capture. Captured certificates are written to the
/// purgatory directory for operator review (capture does not grant trust).
///
/// Usage: mtls-hello [advertised-port] [options]
/// Positional defaults: 8443
/// Options:
///   --version                Print version and exit
///   --multicast-group=239.255.42.42
///   --multicast-port=4242
///   --multicast-interval=5   (seconds)
///   --no-multicast
///   --data-dir=DIR           Derive hosts/purgatory/scripts paths from DIR
///   --trust-dir=DIR          Override hosts directory (default: <data-dir>/hosts)
///   --purgatory-dir=DIR      Override purgatory directory (default: <data-dir>/purgatory)
///
/// Environment variables used by discovery and the sync callback:
///   HOST_NAME                Hostname advertised to peers (default: system hostname)
///   CALLBACK_SCRIPT          Path to on-discover.sh (default: <data-dir>/scripts/on-discover.sh)
///   OUR_CERT                 Client certificate for outgoing mTLS sync calls
///   OUR_KEY                  Client key for outgoing mTLS sync calls
///   REPOS_ROOT               Directory containing bare git repositories to sync
module app;

import vibe.core.core;
import vibe.core.log;

import multicast;
import trust;

import std.conv : to;
import std.datetime : seconds;
import std.file : exists, mkdirRecurse;
import std.path : buildPath, dirName, expandTilde;
import std.process : environment, execute;
import std.socket : Socket;
import std.stdio : writeln;
import std.string : startsWith;

import version_ : appVersion;

extern(C) void onShutdownSignal(int) nothrow @nogc @system
{
	multicast.requestShutdown();
}

struct ServerConfig
{
	/// HTTPS port advertised to peers via multicast. Apache httpd is the
	/// actual listener; this binary does not open the HTTPS socket itself.
	ushort port = 8443;
	string dataDir;
	MulticastConfig multicast;
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
	cfg.multicast.hostName = environment.get("HOST_NAME", Socket.hostName);
	cfg.multicast.callbackScript = environment.get("CALLBACK_SCRIPT", "");
	cfg.multicast.trustDir = cfg.trust.trustDir;
	cfg.multicast.purgatoryDir = cfg.trust.purgatoryDir;

	if (cfg.dataDir.length > 0)
	{
		if (cfg.multicast.callbackScript.length == 0)
			cfg.multicast.callbackScript = cfg.dataDir ~ "/scripts/on-discovery.d/_run-parts.sh";
		if (!cfg.trust.trustDirExplicit)
			cfg.trust.trustDir = cfg.dataDir ~ "/hosts";
		if (!cfg.trust.purgatoryDirExplicit)
			cfg.trust.purgatoryDir = cfg.dataDir ~ "/purgatory";
		cfg.multicast.purgatoryDir = cfg.trust.purgatoryDir;

		// Best-effort migration from the legacy certs/ layout to the flat layout.
		migrateLegacyLayout(cfg.dataDir, cfg.multicast.hostName, cfg.multicast.callbackScript);
	}

	mkdirRecurse(cfg.trust.trustDir.expandTilde);
	mkdirRecurse(cfg.trust.purgatoryDir.expandTilde);

	logInfo("advertising HTTPS port %d to multicast peers", cfg.port);
	logInfo("trust directory: %s", cfg.trust.trustDir);
	logInfo("purgatory directory: %s", cfg.trust.purgatoryDir);

	if (cfg.multicast.enabled)
		logInfo("multicast discovery on %s:%d (interval %s)",
			cfg.multicast.group, cfg.multicast.port, cfg.multicast.interval);

	startMulticastDiscovery(cfg.port, cfg.multicast);

	if (cfg.multicast.enabled)
	{
		import core.sys.posix.signal : signal, SIGINT, SIGTERM;
		disableDefaultSignalHandlers();
		signal(SIGTERM, &onShutdownSignal);
		signal(SIGINT, &onShutdownSignal);
	}
	if (cfg.multicast.enabled)
	{
		runTask(() @trusted nothrow {
			while (!multicast.isShutdown())
			{
				try
				{
					processCaptureQueue();
				}
				catch (Exception e)
				{
					logWarn("capture queue worker error: %s", e.msg);
				}
			}
			exitEventLoop();
		});
	}

	runEventLoop();
}

/// Best-effort migration from the legacy `certs/` layout. Runs the shared
/// migration script synchronously; any failure is logged and ignored so the
/// daemon still starts with the new default paths.
private void migrateLegacyLayout(string dataDir, string hostName, string callbackScript)
{
	if (!exists(buildPath(dataDir, "certs")))
		return;

	string script;
	if (callbackScript.length > 0)
	{
		auto cand = buildPath(dirName(callbackScript), "migrate-layout.sh");
		if (exists(cand))
			script = cand;
	}
	if (script.length == 0)
	{
		auto cand = "scripts/migrate-layout.sh";
		if (exists(cand))
			script = cand;
	}
	if (script.length == 0)
	{
		logWarn("legacy certs/ layout present but migrate-layout.sh not found; skipping");
		return;
	}

	try
	{
		execute(["bash", script, dataDir, hostName]);
	}
	catch (Exception e)
	{
		logWarn("layout migration failed: %s", e.msg);
	}
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
			default: break;
		}
	}

	for (; i < args.length; i++)
	{
		auto a = args[i];
		if (a == "--no-multicast")
			cfg.multicast.enabled = false;
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
		else if (a == "--trust-dir")
		{
			if (i + 1 >= args.length || args[i + 1].startsWith("--"))
				throw new Exception("--trust-dir requires a value");
			cfg.trust.trustDir = args[++i];
			cfg.trust.trustDirExplicit = true;
		}
		else if (a.startsWith("--trust-dir="))
		{
			cfg.trust.trustDir = a["--trust-dir=".length .. $];
			cfg.trust.trustDirExplicit = true;
		}
		else if (a == "--purgatory-dir")
		{
			if (i + 1 >= args.length || args[i + 1].startsWith("--"))
				throw new Exception("--purgatory-dir requires a value");
			cfg.trust.purgatoryDir = args[++i];
			cfg.trust.purgatoryDirExplicit = true;
		}
		else if (a.startsWith("--purgatory-dir="))
		{
			cfg.trust.purgatoryDir = a["--purgatory-dir=".length .. $];
			cfg.trust.purgatoryDirExplicit = true;
		}
	}

	return cfg;
}
