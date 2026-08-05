# Quickstart: Wire Discovery Callback

**Branch**: `008-wire-discovery-callback` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## 1. Set environment variables

The server reads these from its process environment:

```sh
export HOST_NAME=alpha
export OUR_CERT=/path/to/client.crt
export OUR_KEY=/path/to/client.key
export REPOS_ROOT=/srv/repos
```

`HOST_NAME` defaults to `localhost` if unset. The others are required by the callback script.

## 2. Start the server

```sh
just run -- 8443 certs/certs/server.crt certs/private/server.key \
  --trust-dir /srv/certs/trusted \
  --purgatory-dir /srv/certs/purgatory
```

The server announces itself as `HOST_NAME=alpha` on the multicast group.

## 3. Verify announcements

On a second machine, capture multicast packets:

```sh
nc -ul 4242 | while read line; do echo "$line"; done
```

You should see:

```json
{"service":"mtls-hello","port":8443,"host":"alpha"}
```

## 4. Trust the peer

Before discovery can trigger a successful sync, the peer's certificate must be trusted:

```sh
cp peer-beta.crt /srv/certs/trusted/beta.crt
```

## 5. Observe the callback

When server `alpha` discovers server `beta`, the server log shows:

```text
[discovery] peer at 192.168.1.5:8443 -> mtls-hello on port 8443
```

And the callback runs, pushing repos from alpha to beta. Check the peer's repo for the new refs:

```sh
git -C /srv/repos/myproject.git branch -a
```

## 6. Testing without a real LAN

The BATS test suite simulates discovery by sending raw UDP packets to the multicast port. Run:

```sh
just test
```
