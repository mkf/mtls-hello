/// Generic script-executing HTTP handlers.
///
/// GET /<name> and POST /<name> are resolved to files in the handlers directory:
///     <handlers-dir>/<name>.<method>          (exact, no extension)
///     <handlers-dir>/<name>.<method>.<ext>    (first match in lexicographic order)
///
/// Query parameters are passed as CGI-style environment variables:
///     QUERY_STRING          raw query string
///     QUERY_<NAME>          one per decoded parameter (non-alphanumerics -> '_')
///     REQUEST_METHOD        GET/POST
///     SCRIPT_NAME           the matched handler name
///     CONTENT_LENGTH        POST body size
///     CONTENT_TYPE          POST content type
///
/// POST bodies are written to a temp file and redirected to the child's stdin.
/// stdout and stderr are captured in temp files. Execution is bounded by
/// scriptTimeout; the child is killed if it does not finish in time.
module handlers;

import vibe.core.core : sleep;
import vibe.core.log;
import vibe.http.common : HTTPMethod;
import vibe.http.server : HTTPServerRequest;

import core.time : Duration, msecs, MonoTime, seconds;

import std.algorithm : sort;
import std.array : empty, join;
import std.conv : to;
import std.datetime : Clock;
import std.file : dirEntries, exists, isFile, read, remove, SpanMode, tempDir, write;
import std.format : format;
import std.process : environment, Pid, kill, spawnProcess, tryWait;
import std.stdio : File, SEEK_SET;
import std.string : startsWith, strip, toLower, toUpper;
import std.uni : isAlphaNum;

struct HandlerConfig
{
	string handlersDir = "handlers";
	Duration scriptTimeout = 10.seconds;
}

struct ScriptResult
{
	int exitCode;
	bool timedOut;
	string stdout;
	string stderr;
}

/// Validate a handler name. Names must be plain slugs without filesystem
/// separators or structural dots.
bool isValidName(string name)
{
	if (name.empty)
		return false;

	foreach (dchar c; name)
	{
		if (c == '/' || c == '\\' || c == '.')
			return false;
	}

	if (name.startsWith("."))
		return false;

	return true;
}

/// Resolve the executable script for a given method and name.
/// Returns an absolute or relative path (as requested), or null if none found.
string resolveScript(HandlerConfig cfg, string method, string name)
{
	if (!isValidName(name))
		return null;

	string methodLower = method.toLower;
	string exact = cfg.handlersDir ~ "/" ~ name ~ "." ~ methodLower;

	if (exact.exists && exact.isFile)
		return exact;

	string prefix = name ~ "." ~ methodLower ~ ".";
	string[] matches;

	try
	{
		foreach (entry; dirEntries(cfg.handlersDir, SpanMode.shallow))
		{
			if (!entry.isFile)
				continue;
			string base = entry.name[cfg.handlersDir.length + 1 .. $];
			if (base.startsWith(prefix))
				matches ~= entry.name;
		}
	}
	catch (Exception e)
	{
		logWarn("failed to scan handlers dir %s: %s", cfg.handlersDir, e.msg);
		return null;
	}

	if (matches.empty)
		return null;

	matches.sort;
	return matches[0];
}

/// Build the environment variables for a script invocation.
/// Inherits the server environment and adds request context.
string[string] buildEnv(HTTPServerRequest req)
{
	string[string] env = environment.toAA;
	// The server runs inside the Guix shell with LD_LIBRARY_PATH pointing at
	// the Guix profile's libraries. Child scripts must not inherit this,
	// otherwise host binaries (e.g. /bin/bash) load the wrong libc and fail.
	env["LD_LIBRARY_PATH"] = "";


	env["REQUEST_METHOD"] = req.method.to!string;
	env["SCRIPT_NAME"] = req.params.get("name", "");

	env["QUERY_STRING"] = req.queryString;

	foreach (key, value; req.query.byKeyValue)
	{
		string safe;
		foreach (dchar c; key)
		{
			if (c.isAlphaNum || c == '_')
				safe ~= c.to!string;
			else
				safe ~= "_";
		}
		if (!safe.empty)
			env["QUERY_" ~ safe.toUpper] = value;
	}

	if (req.method == HTTPMethod.POST)
	{
		auto cl = req.headers.get("Content-Length", "0");
		env["CONTENT_LENGTH"] = cl;
		auto ct = req.headers.get("Content-Type", "");
		if (!ct.empty)
			env["CONTENT_TYPE"] = ct;
	}

	return env;
}

private string makeTempPath(string suffix)
{
	static ulong counter = 0;
	counter++;
	return format("%s/mtls-hello-%s-%s.%s", tempDir, Clock.currTime.stdTime, counter, suffix);
}

private void safeRemove(string path)
{
	try { remove(path); } catch (Exception) {}
}

/// Execute a script synchronously. This runs in the request-handling fiber
/// but yields via `sleep()` so the event loop is not blocked. The body is
/// written to a named temp file; stdout/stderr are captured in named temp files
/// to avoid std.stdio.File portability issues (File.tmpfile was unreliable in
/// this environment).
ScriptResult executeScript(HandlerConfig cfg, string scriptPath, string[string] env, ubyte[] body)
{
	ScriptResult res;

	string inPath = makeTempPath("in");
	string outPath = makeTempPath("out");
	string errPath = makeTempPath("err");

	scope (exit)
	{
		safeRemove(inPath);
		safeRemove(outPath);
		safeRemove(errPath);
	}

	// Prepare stdin file. The output files are created/truncated here.
	write(inPath, body);
	File outFile = File(outPath, "w+b");
	File errFile = File(errPath, "w+b");
	File inFile = File(inPath, "rb");

	Pid pid;
	try
	{
		pid = spawnProcess(scriptPath, inFile, outFile, errFile, env);
	}
	catch (Exception e)
	{
		res.exitCode = 127;
		res.stderr = "failed to spawn script: " ~ e.msg;
		return res;
	}

	auto deadline = MonoTime.currTime + cfg.scriptTimeout;

	while (true)
	{
		auto tw = tryWait(pid);
		if (tw.terminated)
		{
			res.exitCode = tw.status;
			break;
		}

		if (MonoTime.currTime > deadline)
		{
			res.timedOut = true;
			res.exitCode = -1;
			try { kill(pid); } catch (Exception) {}
			try { tryWait(pid); } catch (Exception) {}
			break;
		}

		sleep(10.msecs);
	}

	// Close our handles before reading the captured files from disk.
	outFile.close();
	errFile.close();
	inFile.close();

	res.stdout = cast(string) read(outPath);
	res.stderr = cast(string) read(errPath);

	return res;
}
