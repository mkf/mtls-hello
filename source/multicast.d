/// LAN multicast discovery for mtls-hello instances.
/// Each instance announces its HTTPS port on a UDP multicast group and listens
/// for announcements from peers on the same LAN.
module multicast;

import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.thread;
import std.datetime : Duration, MonoTime, msecs, seconds;
import std.file : exists;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.process : Config, environment, spawnProcess;
import std.socket;
import std.stdio;
import std.string : strip;


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

		while (true)
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
		auto peerCertFile = cfg.trustDir.length == 0
			? peerHost ~ ".crt"
			: format("%s/%s.crt", cfg.trustDir, peerHost);
		auto peerNetloc = format("%s:%d", addr.toAddrString(), peerPort);

		auto env = environment.toAA;
		env["HOST_NAME"] = cfg.hostName;
		env["PEER_NETLOC"] = peerNetloc;
		env["PEER_CERT_FILE"] = peerCertFile;
		env["OUR_CERT"] = ourCert;
		env["OUR_KEY"] = ourKey;
		env["REPOS_ROOT"] = reposRoot;

		try
		{
			if (!exists(cfg.callbackScript))
			{
				stderr.writefln("multicast warning: failed to spawn callback %s: file not found",
					cfg.callbackScript);
			}
			else
			{
				spawnProcess(["bash", cfg.callbackScript],
					stdin, stdout, stderr, env, Config.none);
			}
		}
		catch (Exception e)
		{
			stderr.writefln("multicast warning: failed to spawn callback %s: %s",
				cfg.callbackScript, e.msg);
		}
	}
	catch (Exception e)
	{
		// Malformed or non-JSON packet — ignore.
	}
}

// Linux multicast API not fully exposed by the D core/sys bindings on this compiler.
private enum IP_MULTICAST_IF = 32;
private enum IP_MULTICAST_TTL = 33;
private enum IP_MULTICAST_LOOP = 34;
private enum IP_ADD_MEMBERSHIP = 35;
