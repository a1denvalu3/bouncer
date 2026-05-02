# Bouncer Architecture

This document explains the technical architecture, execution flow, and network isolation model of **Bouncer**, an automated, continuous security review tool.

## High-Level System Architecture

Bouncer operates using a nested container architecture. The main application runs inside a privileged Docker container, which allows it to spawn heavily restricted, ephemeral `systemd-nspawn` sandboxes for each Pull Request it reviews.

```text
                            GitHub
                      (PRs & Security Repo)
                               ^
                               | (Poll PRs & Submit Reports)
                               v
+-----------------------------------------------------------------+
|                  Bouncer (Docker Container)                     |
|                                                                 |
|  +-----------------+     +----------------+     +------------+  |
|  |     Poller      |     |     State      |     |    /out    |  |
|  | (review.sh)     |---->|  (state.json)  |     |  (Volume)  |  |
|  +--------+--------+     +----------------+     +------^-----+  |
|           |                                            |        |
|           |                                            |        |
|           |                                            |        |
|           |                                            |        |
|           |                                            |        |
|           v (Spawns Ephemeral Sandbox)                 |        |
|  +-----------------------------------------------------------+  |
|  |                 systemd-nspawn Sandbox                    |  |
|  |                 (--volatile=overlay)                      |  |
|  |                                                           |  |
|  |   +-------------------+         +---------------------+   |  |
|  |   |    opencode-ai    |         | Target PR Codebase  |   |  |
|  |   | (LLM agent runner)|<------->| (Diffs & full repo) |   |  |
|  |   +---------+---------+         +---------------------+   |  |
|  |             |                                             |  |
|  +-------------|---------------------------------------------+  |
+----------------|------------------------------------------------+
                 | (API Requests)
                 v
            OpenRouter
            (LLM APIs)
```

### Components:
1. **Poller & Dispatcher (`review.sh`)**: An outer loop running inside the host Docker container that continuously polls configured GitHub repositories for new, updated, or un-reviewed PRs. It checks against `ALLOWED_AUTHOR_ASSOCIATIONS` and handles basic rate-limiting/timeouts. Once a PR is selected, it fetches the PR branch, prepares the workspace context (including a custom `prompt_template.txt`), and spins up the inner sandbox in parallel.
2. **Manual Dispatcher (`review_pr.sh`)**: A utility script allowing manual invocation to review a specific PR immediately, bypassing the polling loop while utilizing the identical sandbox infrastructure.
3. **State & Metrics**: Tracks which commit hashes have already been reviewed to prevent redundant work. Saved to `state.json` inside the local `/out` volume.
4. **systemd-nspawn Sandbox**: An isolated Linux environment (namespace container) instantiated specifically for a single PR review. It is built using an ephemeral RAM disk overlay (`--volatile=overlay`) to ensure it boots instantly and prevents any filesystem state from leaking between reviews.
5. **opencode-ai**: The AI agent executing inside the sandbox. It is given the code diff and instructed to find vulnerabilities, draft Proof of Concepts (PoCs), and test them against the isolated codebase.

---

## Nested Network Architecture

Because Bouncer relies on an AI to run live tests, compile code, and potentially spin up test servers, we must allow network access while simultaneously preventing collisions between concurrently running AI instances.

Bouncer solves this by provisioning a dedicated virtual bridge network structure when the main Docker container boots (`entrypoint.sh`).

```text
+-------------------------------------------------------------------------+
|                        Bouncer Docker Container                         |
|                                                                         |
|                                         +-----------------------+       |
|  +--------------------------+           |     DHCP Server       |       |
|  |    Outbound Internet     |<----------| (dnsmasq on bridge)   |       |
|  | (iptables NAT masquerade)|           +-----------+-----------+       |
|  +-------------^------------+                       |                   |
|                |                                    |                   |
|                +------------------------------------+                   |
|                                |                                        |
|                     +----------+----------+                             |
|                     |  br-nspawn (Bridge) |                             |
|                     |    10.200.0.1/16    |                             |
|                     +----+-----------+----+                             |
|                          |           |                                  |
|          (veth pair)     |           |     (veth pair)                  |
|                          |           |                                  |
|             +------------+           +------------+                     |
|             |                             |                             |
|   +---------+---------+         +---------+---------+                   |
|   |    Sandbox 1      |         |    Sandbox 2      |   Isolated        |
|   | (systemd-nspawn)  |         | (systemd-nspawn)  |   Network Spaces  |
|   |                   |         |                   |                   |
|   | eth0: 10.200.x.y  |         | eth0: 10.200.x.z  |   (No port        |
|   | (DHCP assigned)   |         | (DHCP assigned)   |    collisions!)   |
|   +-------------------+         +-------------------+                   |
|                                                                         |
+-------------------------------------------------------------------------+
```

### Network Flow and Setup:
1. **Virtual Bridge**: The host container creates `br-nspawn`, assigning it `10.200.0.1` as the gateway.
2. **DHCP via dnsmasq**: A local DHCP server is bound exclusively to `br-nspawn`. As sandboxes spin up, they request an IP address, and `dnsmasq` dynamically assigns them an IP from the `10.200.0.0/16` subnet.
3. **veth Pairs**: Every `systemd-nspawn` container is spawned with `--network-bridge=br-nspawn`, which provisions a virtual ethernet (`veth`) pair. One end connects to the namespace's `eth0`, and the other attaches to `br-nspawn`.
4. **No Port Collisions**: Every PR agent operates inside its own Network Namespace. The loopback interfaces (`localhost`) are completely segregated. Agent A can start a server on `localhost:8080` while Agent B also starts a server on `localhost:8080` without any conflicts or visibility into each other's environments.
5. **Outbound Internet via NAT**: The AI still needs access to package managers (`npm`, `cargo`, `pip`). Outbound packets from the `10.200.x.x` subnets are masqueraded by `iptables` running in the main Docker container, sharing its external outbound connection while preventing inbound external access into the sandboxes.

## Execution Lifecycle

1. **Wait**: `review.sh` sleeps based on `SLEEP_DURATION`.
2. **Poll**: Checks GitHub API for open PRs across `REPOS`.
3. **Filter**: Skips PRs lacking valid author associations or those already in `state.json`.
4. **Bootstrap**: Checks out the repo, pulls the branch, and writes workspace contexts.
5. **Sandbox Init**: Starts the `systemd-nspawn` container using a unique machine name to avoid collision.
6. **Execution**: The AI runs for up to `REVIEW_TIMEOUT`. Tests hypotheses and scripts PoCs.
7. **Cleanup**: Container is destroyed (discarding the volatile overlay).
8. **Report**: If a vulnerability report was generated, `bouncer` submits it as a new Pull Request to the private `REPORT_REPO`. Metric files are stored safely in `/out`.
