/// LAN multicast discovery for mtls-hello instances.
/// Each instance announces its HTTPS port on a UDP multicast group and listens
/// for announcements from peers on the same LAN.
module multicast;

private __gshared bool g_shutdown;

/// Request the multicast discovery thread to stop.
void requestShutdown() @trusted nothrow @nogc
{
	g_shutdown = true;
}

/// Query whether shutdown has been requested.
bool isShutdown() @trusted nothrow @nogc
{
	return g_shutdown;
}

import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.thread;
import std.datetime : Duration, MonoTime, msecs, seconds;
import std.file : exists, dirEntries, SpanMode;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : Config, environment, spawnProcess;
import core.sync.condition : Condition;
import core.sync.mutex;
import std.algorithm : startsWith;
import std.socket;
import std.stdio;
import std.string : strip;
import trust : detectPeerCertificate;


private enum string SERVICE_NAME = "mtls-hello";

struct MulticastConfig
{
	string group = "239.255.42.42";
	ushort port = 4242;
	Duration interval = 5.seconds;
	bool enabled = true;
	/// Hostname advertised to peers and used in the discovery callback env.
	string hostName = "localhost";
	/// Directory containing trusted peer certificates (<hostname>.crt).
	string trustDir = "";
	/// Directory where discovered peer certificates are captured for review.
	string purgatoryDir = "";
	/// Path to the discovery callback script (empty if not configured).
	string callbackScript = "";
}

/// Start multicast discovery in a background thread.
void startMulticastDiscovery(ushort httpPort, MulticastConfig cfg)
{
	if (!cfg.enabled)
		return;

	auto t = new Thread(() => multicastWorker(httpPort, cfg));
	t.isDaemon = true;
	t.start();
}

private void multicastWorker(ushort httpPort, MulticastConfig cfg)
{
	try
	{
		auto sock = new Socket(AddressFamily.INET, SocketType.DGRAM, ProtocolType.UDP);
		scope (exit)
			sock.close();

		// Allow multiple instances on the same host to bind the same port.
		sock.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);

		// Bind to the multicast port on all interfaces.
		sock.bind(new InternetAddress("0.0.0.0", cfg.port));

		auto groupAddr = new InternetAddress(cfg.group, cfg.port);

		// Set the default outgoing interface for multicast (INADDR_ANY lets the
		// kernel pick a multicast-capable interface). If no interface supports
		// multicast, send-only is still useful; we warn instead of aborting.
		uint ifaddr = 0; // INADDR_ANY
		if (setsockopt(sock.handle, IPPROTO_IP, IP_MULTICAST_IF, &ifaddr, uint.sizeof) != 0)
			stderr.writeln("multicast warning: failed to set outgoing interface");

		// Join the multicast group. InternetAddress.addr returns the address
		// in host byte order on this D runtime, but ip_mreq.imr_multiaddr
		// expects network byte order. Convert with htonl.
		import core.sys.posix.netinet.in_ : htonl;
		uint[2] mreq = [htonl(groupAddr.addr), 0]; // INADDR_ANY interface
		if (setsockopt(sock.handle, IPPROTO_IP, IP_ADD_MEMBERSHIP, mreq.ptr, mreq.sizeof) != 0)
			stderr.writeln("multicast warning: failed to join group ", cfg.group, "; continuing send-only");

		// Keep announcements on the local LAN (TTL = 1).
		ubyte ttl = 1;
		if (setsockopt(sock.handle, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, ubyte.sizeof) != 0)
			throw new Exception("Failed to set multicast TTL");

		// Loopback so multiple instances on the same host discover each other.
		ubyte loop = 1;
		if (setsockopt(sock.handle, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, ubyte.sizeof) != 0)
			throw new Exception("Failed to enable multicast loopback");

		// Short receive timeout so we can send announcements periodically.
		sock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 500.msecs);

		auto lastAnnounce = MonoTime.currTime - cfg.interval;
		ubyte[1024] buf;
		Address senderAddr = new InternetAddress(0, 0);

		while (!isShutdown())
		{
			auto now = MonoTime.currTime;
			if (now - lastAnnounce >= cfg.interval)
			{
				auto msg = announceMessage(httpPort, cfg);
				stderr.writefln("[multicast] announcement: %s", msg.strip);
				sock.sendTo(cast(const(ubyte)[]) msg, groupAddr);
				lastAnnounce = now;
			}

			auto ourCert = environment.get("OUR_CERT", "");
			auto ourKey = environment.get("OUR_KEY", "");
			auto reposRoot = environment.get("REPOS_ROOT", "");

			auto n = sock.receiveFrom(buf, senderAddr);
			if (n > 0)
			{
				auto text = cast(string) buf[0 .. n];
				processAnnouncement(text, senderAddr, httpPort, cfg, ourCert, ourKey, reposRoot);
			}
		}
	}
	catch (Exception e)
	{
		stderr.writeln("multicast discovery error: ", e.msg);
	}
}

private string announceMessage(ushort httpPort, MulticastConfig cfg)
{
	auto j = JSONValue([
		"service": JSONValue(SERVICE_NAME),
		"port": JSONValue(httpPort),
		"host": JSONValue(cfg.hostName),
	]);
	return j.toString() ~ "\n";
}

private bool isPeerAlreadyKnown(string hostName, string trustDir, string purgatoryDir)
{
	if (trustDir.length > 0)
	{
		auto trustPath = buildPath(trustDir, hostName ~ ".crt");
		if (exists(trustPath))
			return true;
	}
	if (purgatoryDir.length > 0)
	{
		foreach (entry; dirEntries(purgatoryDir, SpanMode.shallow))
		{
			import std.path : baseName;
			auto name = baseName(entry.name);
			if (name.startsWith(hostName ~ "."))
				return true;
		}
	}
	return false;
}

private void processAnnouncement(string text, Address sender, ushort ownPort,
	MulticastConfig cfg, string ourCert, string ourKey, string reposRoot)
{
	text = text.strip();
	if (text.length == 0)
		return;
	try
	{
		auto j = parseJSON(text);
		if (j["service"].str != SERVICE_NAME)
			return;
		auto peerPort = j["port"].get!ushort;
		auto addr = cast(InternetAddress) sender;
		if (addr is null)
			return;

		// Ignore our own packets (loopback is enabled, so we hear ourselves).
		// A real implementation would include an instance id; here we just skip
		// announcements whose port matches ours from the local address.
		if (peerPort == ownPort)
			return;

		stderr.writefln("[discovery] peer at %s:%d -> mtls-hello on port %d",
			addr.toAddrString(), addr.port, peerPort);

		auto peerHost = ("host" in j) ? j["host"].str : "unknown";
		auto peerNetloc = format("%s:%d", addr.toAddrString(), peerPort);

		if (isPeerAlreadyKnown(peerHost, cfg.trustDir, cfg.purgatoryDir))
		{
			stderr.writefln("[discovery] peer %s already known; skipping capture", peerHost);
			return;
		}

		// Enqueue a capture request for the main event loop worker. The worker
		// runs the actual mTLS handshake and captures the peer certificate,
		// then spawns the callback with the real purgatory path.
		try
		{
			pushCaptureRequest(CaptureRequest(
				addr.toAddrString(), peerPort, ourCert, ourKey,
				cfg.purgatoryDir, cfg.callbackScript, cfg.hostName,
				peerNetloc, reposRoot));
		}
		catch (Exception e)
		{
			stderr.writefln("multicast warning: failed to enqueue peer cert capture for %s: %s",
				peerNetloc, e.msg);
		}
	}
	catch (Exception e)
	{
		// Malformed or non-JSON packet — ignore.
	}
}

unittest
{
	import std.file : mkdirRecurse, remove, rmdirRecurse, write;
	import std.path : buildPath;

	auto tmp = "/tmp/mtls-test-known-peer";
	scope (exit) rmdirRecurse(tmp);

	mkdirRecurse(buildPath(tmp, "hosts"));
	mkdirRecurse(buildPath(tmp, "purgatory"));

	// Not known when dirs are empty.
	assert(!isPeerAlreadyKnown("alpha", buildPath(tmp, "hosts"), buildPath(tmp, "purgatory")));

	// Known when a trust file exists.
	write(buildPath(tmp, "hosts", "alpha.crt"), "test");
	assert(isPeerAlreadyKnown("alpha", buildPath(tmp, "hosts"), buildPath(tmp, "purgatory")));

	// Known when a purgatory file exists.
	remove(buildPath(tmp, "hosts", "alpha.crt"));
	write(buildPath(tmp, "purgatory", "alpha.deadbeef.crt"), "test");
	assert(isPeerAlreadyKnown("alpha", buildPath(tmp, "hosts"), buildPath(tmp, "purgatory")));

	// Different hostname is not known.
	assert(!isPeerAlreadyKnown("beta", buildPath(tmp, "hosts"), buildPath(tmp, "purgatory")));
}

// Linux multicast API not fully exposed by the D core/sys bindings on this compiler.
private enum IP_MULTICAST_IF = 32;
private enum IP_MULTICAST_TTL = 33;
private enum IP_MULTICAST_LOOP = 34;
private enum IP_ADD_MEMBERSHIP = 35;

private struct CaptureRequest
{
	string peerHost;
	ushort peerPort;
	string ourCert;
	string ourKey;
	string purgatoryDir;
	string callbackScript;
	string hostName;
	string peerNetloc;
	string reposRoot;
}

private __gshared CaptureRequest[] s_captureQueue;
private __gshared Mutex s_captureMutex;
private __gshared Condition s_captureCondition;

private void ensureCaptureMutex()
{
	if (s_captureMutex is null)
		s_captureMutex = new Mutex();
}

private void ensureCaptureCondition()
{
	ensureCaptureMutex();
	if (s_captureCondition is null)
		s_captureCondition = new Condition(s_captureMutex);
}

private void pushCaptureRequest(CaptureRequest req) @trusted
{
	ensureCaptureCondition();
	bool wasEmpty;
	synchronized (s_captureMutex)
	{
		wasEmpty = s_captureQueue.length == 0;
		s_captureQueue ~= req;
	}
	if (wasEmpty)
		s_captureCondition.notify();
}

/// Process queued capture requests in the main event loop. This is called
/// periodically from a vibe.d task started in app.d.
void processCaptureQueue() @trusted nothrow
{
	try
	{
		ensureCaptureCondition();
		CaptureRequest request;
		synchronized (s_captureMutex)
		{
			if (s_captureQueue.length == 0)
				s_captureCondition.wait(1.seconds);
			if (s_captureQueue.length > 0)
			{
				request = s_captureQueue[0];
				s_captureQueue = s_captureQueue[1 .. $];
			}
		}

		if (request.peerHost.length == 0)
			return;

		try
		{
			auto capture = detectPeerCertificate(request.peerHost, request.peerPort,
				request.ourCert, request.ourKey, request.purgatoryDir);

			auto env = environment.toAA;
			env["HOST_NAME"] = request.hostName;
			env["PEER_NETLOC"] = request.peerNetloc;
			env["PEER_CERT_FILE"] = capture.purgatoryPath;
			env["OUR_CERT"] = request.ourCert;
			env["OUR_KEY"] = request.ourKey;
			env["REPOS_ROOT"] = request.reposRoot;

			if (capture.purgatoryPath.length == 0)
				stderr.writefln("discovery warning: failed to capture peer certificate for %s",
					request.peerNetloc);
			else
				stderr.writefln("discovery: captured peer certificate for %s at %s",
					capture.hostname, capture.purgatoryPath);

			if (!exists(request.callbackScript))
				stderr.writefln("multicast warning: failed to spawn callback %s: file not found",
					request.callbackScript);
			else
				spawnProcess(["bash", request.callbackScript],
					stdin, stdout, stderr, env, Config.none);
		}
		catch (Exception e)
		{
			stderr.writefln("multicast warning: peer cert capture or callback failed for %s: %s",
				request.peerNetloc, e.msg);
		}
	}
	catch (Exception)
	{
		// Nothing we can do here.
	}
}
