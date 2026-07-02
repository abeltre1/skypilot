# Multiple HPC systems + OpenShift (OCP) with SkyPilot

A prototype for registering several HPC clusters **and** an OpenShift (OCP)
cluster as SkyPilot infra, so you can launch jobs across all of them from one
API server.

**Good news:** SkyPilot already supports these natively — nothing in `sky/` core
needs to change. This bundle is the *wiring*: example config files, sample
tasks, and a verification script.

| Target | SkyPilot cloud | How it's registered |
| --- | --- | --- |
| HPC (Slurm) | `slurm` | `~/.slurm/config` + `slurm.*` in `~/.sky/config.yaml` |
| OpenShift (OCP) | `kubernetes` | `oc login` context + `kubernetes.*` in `~/.sky/config.yaml` |
| Bare SSH / non-Slurm nodes | `ssh` (SSH Node Pool) | `~/.sky/ssh_node_pools.yaml` + `sky ssh up` |

## Files

```
sky-config.yaml       # -> ~/.sky/config.yaml   (slurm + kubernetes/OCP + ssh blocks)
slurm-config          # -> ~/.slurm/config      (one Host per HPC cluster; MFA pattern)
ssh_node_pools.yaml   # -> ~/.sky/ssh_node_pools.yaml (non-Slurm / Flux fallback)
ocp-pod-config.yaml   # OpenShift restricted-SCC pod_config reference
tasks/task-hpc.yaml   # GPU probe on a Slurm cluster
tasks/task-ocp.yaml   # probe on the OCP cluster
tasks/task-any.yaml   # multi-infra failover probe
verify.sh             # static + (optional) live verification
```

## Setup

Everything below is done on the **host running the SkyPilot API server** — the
machine that has network + SSH reach to your clusters.

### 1. Install

```bash
uv pip install -e ".[kubernetes]"   # OCP support
# Slurm support ships with SkyPilot; ensure `ssh` and `sbatch` reach the cluster.
```

### 2. Register HPC (Slurm) clusters

Copy `slurm-config` to `~/.slurm/config` and edit the `Host` blocks. Each Host
is one Slurm cluster; SkyPilot SSHes to the login node and runs `sbatch`/`squeue`.

```bash
mkdir -p ~/.slurm && cp slurm-config ~/.slurm/config   # then edit
ssh -F ~/.slurm/config hpc1 sinfo                        # sanity check
```

> Regions map to Slurm clusters and zones to partitions. Map accelerators to
> partitions with `slurm.cluster_configs.<name>.gpu_partition_map` in
> `~/.sky/config.yaml`.

#### MFA (OTP + YubiKey) — the important part

Interactive MFA can't be scripted, and SkyPilot's Slurm *control* commands
(`sbatch`/`squeue`) use a **paramiko** SSH client that does **not** reuse OpenSSH
`ControlMaster` sockets. The workaround: authenticate **once** interactively to
open a persistent master, then route SkyPilot through it with `ProxyCommand`
(paramiko *does* honor `ProxyCommand`, and the `ssh -W` inside it reuses the
already-authenticated master).

Add a master host to `~/.ssh/config`:

```
Host hpc2-cm
    HostName login.hpc2.example.com
    User myuser
    ControlMaster auto
    ControlPath ~/.ssh/cm/%r@%h:%p
    ControlPersist 12h
```

Open it once (this is where you enter the OTP and touch the YubiKey):

```bash
mkdir -p ~/.ssh/cm
ssh hpc2-cm true          # authenticate once; master stays warm ~12h
```

Point the Slurm Host at it (already in `slurm-config`):

```
Host hpc2
    HostName login.hpc2.example.com
    User myuser
    ProxyCommand ssh -W %h:%p hpc2-cm
```

Re-run `ssh hpc2-cm true` whenever the 12h `ControlPersist` window lapses.

**Fallback if the paramiko/MFA path is unreliable at your site:** run the
SkyPilot API server *on the login node itself* (or a node with passwordless
access to it). Then `sbatch`/`squeue` are local and MFA never re-triggers.

### 3. Register OpenShift (OCP)

Log in with the OpenShift CLI to create a kubeconfig context, then confirm it:

```bash
oc login https://api.ocp.example.com:6443       # creates a kube context
kubectl config get-contexts                     # copy the OCP context name
```

Put that context name into `kubernetes.allowed_contexts` and
`kubernetes.context_configs` in `~/.sky/config.yaml` (see `sky-config.yaml`).

OCP's default **`restricted-v2` SCC** assigns an arbitrary non-root UID and
forbids privilege escalation. The included `pod_config` (also in
`ocp-pod-config.yaml`) declares a compliant `securityContext`. SkyPilot pins no
`runAsUser` and picks sudo-vs-direct at runtime via `id -u`, so an arbitrary UID
works out of the box.

If a workload needs root or a fixed UID, an admin can grant a service account a
looser SCC and you reference it via `remote_identity`:

```bash
oc create serviceaccount skypilot -n <namespace>
oc adm policy add-scc-to-user anyuid -z skypilot -n <namespace>
```

> **Ports:** SkyPilot emits Kubernetes `Ingress`, not OCP `Route`s. Use
> `kubernetes.ports: loadbalancer`, or create a `Route` out-of-band if you need
> external service exposure.

### 4. Drop in the SkyPilot config

```bash
cp sky-config.yaml ~/.sky/config.yaml    # then edit names to match your env
```

## Scheduler support: Slurm vs Flux

- **Slurm** — natively supported. Use the `slurm` cloud as above.
- **Flux** — **not** natively supported (SkyPilot ships a Slurm integration
  only). Two honest options:
  1. **SSH Node Pool** (`ssh_node_pools.yaml` + `sky ssh up`): where your admins
     permit a user-space K3s on the login/compute nodes, SkyPilot schedules onto
     the nodes directly via K3s (it does **not** submit to Flux). Good for
     interactive/dev capacity; check with your HPC admins first.
  2. **Treat as future work** — a native Flux connector would be new core code
     in `sky/clouds/` + `sky/provision/`, outside this config-only prototype.

## Verify

```bash
# Static checks — no jobs submitted, safe to run anytime:
./verify.sh
#   - validates ~/.sky/config.yaml against the schema
#   - `sky check` (Slurm clusters, K8s/OCP contexts enabled?)
#   - `sky check ssh` (SSH Node Pools)
#   - `sky status` shows "Enabled Infra:"

# Live end-to-end (launches + tears down a probe on each target):
./verify.sh --live
```

Manual spot checks:

```bash
sky launch --infra slurm/hpc1 tasks/task-hpc.yaml -c hpc-probe   # sbatch -> nvidia-smi
sky launch --infra k8s        tasks/task-ocp.yaml -c ocp-probe   # OCP pod -> id -u / nproc
sky launch                    tasks/task-any.yaml -c any-probe   # failover across all
sky down -y hpc-probe ocp-probe any-probe
```

## Verified end-to-end (local Slurm testbed)

The Slurm path in this bundle is verified against a **real, live Slurm 23.11
cluster** (single node, Ubuntu 24.04) built by
[`local-testbed/setup-local-slurm.sh`](local-testbed/setup-local-slurm.sh) —
SkyPilot connects over SSH to the login node as an unprivileged user and drives
`sbatch`/`squeue`, exactly as it would on a production HPC system.

```console
$ sky check slurm
  Slurm: enabled [compute]
    Allowed clusters:
    └── demo-hpc: enabled.

$ sky launch -y -c hpc-demo --infra slurm/demo-hpc --cpus 2 -- \
    'echo "Hello from SkyPilot on Slurm"; echo "node: $(hostname), user: $(id -un)"; echo "slurm job: $SLURM_JOB_ID"'
Considered resources (1 node):
----------------------------------------------------------------------------
 INFRA              INSTANCE   vCPUs   Mem(GB)   GPUS   COST ($)   CHOSEN
----------------------------------------------------------------------------
 Slurm (demo-hpc)   -          2       2         -      0.00        ✔
----------------------------------------------------------------------------
⚙︎ Launching on Slurm demo-hpc (cpu).
✓ Cluster launched: hpc-demo.
⚙︎ Job submitted, ID: 1
(sky-cmd, pid=5718) Hello from SkyPilot on Slurm
(sky-cmd, pid=5718) node: vm, user: hpcuser
(sky-cmd, pid=5718) slurm job: 10
✓ Job finished (status: SUCCEEDED).
```

On the Slurm side this shows up as a normal user job:

```console
$ squeue
   JOBID PARTITION     NAME     USER ST   TIME  NODES NODELIST(REASON)
      10       cpu hpc-demo  hpcuser  R   0:27      1 vm
```

To reproduce anywhere (VM/container, root):

```bash
sudo bash local-testbed/setup-local-slurm.sh
sky api start && sky check slurm
sky launch -y -c hpc-demo --infra slurm/demo-hpc --cpus 2 -- hostname
```

> Tip surfaced by the live run: if a partition has no `MaxTime`/`DefaultTime`,
> SkyPilot warns that jobs submitted without `--time` can hang behind
> maintenance reservations — set `slurm.sbatch_options.time` (or
> `cluster_configs.<name>.sbatch_options.time`) as done in `sky-config.yaml`.

## Restricted networks (egress proxies, blocked domains)

Lessons from bringing this up behind a TLS-intercepting egress proxy — the
same class of problems you will hit on locked-down HPC networks:

1. **Proxy env must reach the SSH user and Slurm jobs.** The node bootstrap
   (conda, pip) runs as your HPC user inside the allocation. Put
   `http(s)_proxy`/`no_proxy` in `/etc/environment` (PAM applies it to SSH
   sessions) or the user's `~/.bashrc` — root's env does not propagate.
2. **TLS-intercepting proxies need the CA everywhere.** `curl` honors the
   system trust store, but `uv` (bundled rustls roots) and `pip` (certifi) do
   not: exports needed are `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`
   (all pointing at the system bundle) and `UV_NATIVE_TLS=true`. The failure
   signatures are `invalid peer certificate: UnknownIssuer` (uv) and
   `self-signed certificate in certificate chain` (pip).
   Two placement gotchas found the hard way:
   - Exports must go at the **top** of `~/.bashrc` — stock Ubuntu `.bashrc`
     returns early for non-interactive shells, so appended lines never reach
     batch jobs.
   - Task `setup:`/`run:` phases execute under the cluster runtime, not a
     login shell — pass the vars through the task instead:
     `sky launch ... --env PIP_CERT=/etc/ssl/certs/ca-certificates.crt ...`
3. **`astral.sh` blocked:** SkyPilot bootstraps `uv` from astral.sh. If only
   PyPI is reachable, pre-seed the `uv` binary at
   `~/.sky_clusters/<cluster>-<userhash>/.local/bin/uv` on the login node —
   the bootstrap skips the download when it is already present
   (`setup-local-slurm.sh` automates this).
4. **`download.pytorch.org` blocked:** `tasks/train-pytorch.yaml` falls back
   to installing torch from PyPI when the PyTorch index is unreachable.

## Notes / limitations (flagged, not hidden)

- Native **Flux** scheduling is out of scope (config-only prototype).
- Auto-creating OCP **Routes** and automatic **SCC** binding are left as
  documented `oc` admin steps.
- Fully unattended **MFA** is impossible by design; the ControlMaster pattern
  reduces it to one interactive auth per `ControlPersist` window.
