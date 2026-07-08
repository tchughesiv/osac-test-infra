# Secure relay access to monitoring services

The central monitoring host (`osac-ci-1`) has a public IP, and its SSH port
sees continuous internet-wide brute-force traffic (thousands of attempts a
day, common for any host with SSH on the open internet). Rather than expose
Grafana/Prometheus/Alertmanager on that public IP directly, they're also
reachable through a **relay machine** — an internal, VPN-reachable, always-on
host that holds a persistent, tightly-restricted SSH tunnel back to the
central host. Anyone who can reach the relay (e.g. anyone on the internal
VPN) can reach the forwarded services; nobody else can, without also opening
those ports on the central host's own public-facing firewall.

This does not replace the central host's own security posture (that's
covered by the broader hardening effort — SSH key-only auth, sudo scoping,
etc.) — it's an additional access path that doesn't require any of those
ports to be reachable from the public internet at all.

## Architecture

```
   internal VPN                                     public internet
  (trusted users)                                   (everyone else)
        |                                                   |
        v                                                   v
  +----------------+                              +--------------------+
  |  relay machine |--- SSH tunnel (outbound,  --->|   central host     |
  |  (always-on,   |    relay-initiated,           |   (osac-ci-1)      |
  |  VPN-reachable)|    restricted key)             |                   |
  |                |                                |  Grafana   :3000  |
  |  :3000  :9091  |<-- forwards to 127.0.0.1 ------|  Prometheus:9091  |
  |  :9093         |    on the central host         |  Alertmgr  :9093  |
  +----------------+                                +--------------------+
```

The relay **initiates** the connection outbound to the central host — the
central host never needs to reach the relay, and no inbound firewall change
is required on the relay's side beyond opening the forwarded ports to
whichever network the trusted users are on (its VPN-facing interface).

## One-time setup

Two scripts, one per side, mirroring the existing `--add-tunnel` pattern
`monitoring-setup.sh` uses for pulling metrics from remote runners — except
this tunnel runs in the opposite direction and for a different purpose
(pushing central's own services out to a relay, not pulling metrics in).

### 1. On the relay machine

```bash
sudo ./monitoring/scripts/setup-tunnel-relay.sh <label> <central-host> <central-tunnel-user> <port> [<port> ...]

# Example: relay to the monitoring central host's Grafana/Prometheus/Alertmanager
sudo ./monitoring/scripts/setup-tunnel-relay.sh osac-ci1 <central-host-ip-or-hostname> grafana-tunnel 3000 9091 9093
```

This creates a dedicated, unprivileged, shell-less local user
(`<label>-tunnel`) and a systemd service holding a persistent,
auto-reconnecting SSH tunnel. It prints the new key's public half and the
exact command to run on the central host next — the tunnel will keep
retrying and failing to connect until that step happens, which is expected.

### 2. On the central host

```bash
sudo ./monitoring/scripts/authorize-tunnel-relay.sh <central-tunnel-user> "<public-key-from-step-1>"
```

This creates a dedicated, unprivileged, shell-less system user
(`<central-tunnel-user>`, e.g. `grafana-tunnel`) and installs the relay's key
into its `authorized_keys` with `restrict,port-forwarding` — critically, this
is an SSH-protocol-level restriction enforced before any shell or sudo is
even reachable. **This key can only forward a connection to a port the
central host already listens on locally; it cannot open a shell, run a
command, or do anything else**, regardless of what OS-level permissions that
account might otherwise have. Verified directly (not just assumed) when this
was set up: an attempt to get a shell with the restricted key is refused
outright, while port forwarding through it works normally.

Both scripts are idempotent — re-running either with the same arguments
detects the existing user/keypair/service and leaves it alone.

## Adding another port, or another relay

- **Another port on the same relay**: re-run `setup-tunnel-relay.sh` with the
  full port list (existing plus new) — it rewrites the systemd unit with the
  complete forward list, then `systemctl restart <label>-tunnel.service` to
  pick it up (a plain re-run alone does *not* restart an already-active
  service, since `systemctl enable --now` is a no-op on something already
  running).
- **A second, independent relay**: pick a different `<label>` on the relay
  side and a different `<central-tunnel-user>` on the central side, so the
  two relays get fully separate identities and neither can be used to
  impersonate or interfere with the other.

## Verifying

From the relay machine, after setup:

```bash
curl -sk https://127.0.0.1:3000/api/health      # Grafana
curl -s  http://127.0.0.1:9091/-/healthy         # Prometheus
curl -s  http://127.0.0.1:9093/-/healthy         # Alertmanager
```

Grafana's TLS certificate is issued for the central host's own address, not
the relay's — expect a certificate name-mismatch warning in the browser when
accessing it via the relay. Safe to click through for internal use; a
proper fix would mean issuing a cert that also covers the relay's hostname
(or terminating TLS at the relay instead), not done as part of this setup.

## Grafana OAuth login only works from one canonical host at a time

Prometheus and Alertmanager don't need authentication, so relaying them is
purely additive. **Grafana is different** — its GitHub OAuth login breaks the
moment you access it from an address other than whichever one `GF_SERVER_ROOT_URL`
and the GitHub OAuth app's callback URL currently agree on. This isn't
cosmetic like the TLS warning above; login fails outright with "Missing
saved oauth state", because the state cookie set on the address you started
from doesn't follow you to the callback redirect (which always targets
whatever `root_url` says, regardless of which address you actually used).

GitHub OAuth Apps only support a single registered callback URL, so only
**one** address can ever be canonical for login. As of this setup, that's
the relay's address, not the central host's own — meaning direct
public-IP-based Grafana *login* no longer works (the dashboards/API would
still be reachable, just not a fresh GitHub sign-in). This was a deliberate
trade made when the relay became the primary access path; see
`monitoring/README.md`'s Grafana setup section for the exact mechanics.

**To switch the canonical host later** (e.g. adding a second relay and
wanting *it* to be canonical instead):
1. Update the GitHub OAuth app's "Authorization callback URL" to the new
   address **first**.
2. Only then update `GF_SERVER_ROOT_URL` — both the live
   `~/.monitoring-server/.env.grafana` on the central host *and*
   `secret/osac/monitoring/grafana-oauth`'s `root_url` field in Vault (so
   the next automated deploy doesn't silently revert it back).
3. Restart `grafana.service`.

Doing this in the other order breaks login from *every* address until both
sides match again — GitHub rejects the request before Grafana's own
state-cookie logic is even reached.

## Troubleshooting

**Tunnel service won't come up / keeps restarting**: check
`journalctl -u <label>-tunnel.service` on the relay. Most likely cause is
the central host hasn't run `authorize-tunnel-relay.sh` yet for this
relay's key, or the two hosts' keys have drifted out of sync (e.g. the
relay's key was regenerated but the central host still has the old one
authorized — re-run `authorize-tunnel-relay.sh` with the current key to fix).

**Changed the port list but the relay still isn't reachable on the new
port**: `setup-tunnel-relay.sh` doesn't restart an already-running service
(see above) — `systemctl restart <label>-tunnel.service` after re-running it.
Also check the relay's own firewall allows the new port on whichever zone
covers its VPN-facing interface.

**Confirming the restriction actually holds** (worth re-checking after any
change to sshd config on the central host):

```bash
# Should be refused:
ssh -i <relay-keyfile> <central-tunnel-user>@<central-host> whoami

# Should work (assuming something's listening on 127.0.0.1:<port> there):
ssh -N -i <relay-keyfile> -L <local-port>:127.0.0.1:<port> <central-tunnel-user>@<central-host> &
curl http://127.0.0.1:<local-port>/...
```
