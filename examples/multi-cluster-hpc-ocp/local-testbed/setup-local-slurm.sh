#!/usr/bin/env bash
# Stand up a REAL single-node Slurm cluster on this machine and wire SkyPilot
# to it over SSH -- a faithful miniature of an HPC system (login node + sbatch)
# for testing the SkyPilot integration end-to-end without touching production.
#
# Verified on Ubuntu 24.04 (Slurm 23.11) inside a container. Run as root.
#
#   sudo bash setup-local-slurm.sh
#   sky check slurm
#   sky launch -y -c hpc-demo --infra slurm/demo-hpc --cpus 2 -- hostname
#
# What it does:
#   1. Installs slurm-wlm + munge + openssh-server
#   2. Configures a 1-node cluster "demo-hpc" (partitions: cpu*, debug)
#   3. Creates user `hpcuser` with SSH key auth (the "HPC account")
#   4. Writes ~/.slurm/config and a minimal slurm block in ~/.sky/config.yaml
set -euo pipefail

[[ $(id -u) -eq 0 ]] || { echo "run as root"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

echo "== [1/6] Install packages =="
apt-get update -qq || true
apt-get install -y -qq slurm-wlm munge openssh-server rsync

echo "== [2/6] munge =="
if [[ ! -s /etc/munge/munge.key ]]; then
    /usr/sbin/mungekey --create --force 2>/dev/null || \
        dd if=/dev/urandom of=/etc/munge/munge.key bs=1k count=1 2>/dev/null
fi
chown munge:munge /etc/munge/munge.key && chmod 600 /etc/munge/munge.key
mkdir -p /run/munge && chown munge:munge /run/munge
pgrep munged >/dev/null || sudo -u munge /usr/sbin/munged || munged --force
munge -n | unmunge >/dev/null && echo "   munge OK"

echo "== [3/6] slurm.conf =="
HOST=$(hostname -s)
MEM=$(free -m | awk '/^Mem:/{print $2 - 1024}')
CPUS=$(nproc)
cat > /etc/slurm/slurm.conf <<EOF
ClusterName=demo-hpc
SlurmctldHost=${HOST}
SlurmUser=root
AuthType=auth/munge
# Container/VM-friendly: no cgroup enforcement
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
SchedulerType=sched/backfill
# Low backfill interval: with accounting_storage/none the main sched loop can
# skip jobs ("invalid account"); backfill picks them up within bf_interval.
SchedulerParameters=bf_interval=5
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU_Memory
AccountingStorageType=accounting_storage/none
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd
StateSaveLocation=/var/spool/slurmctld
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
ReturnToService=2
MpiDefault=none
NodeName=${HOST} CPUs=${CPUS} RealMemory=${MEM} State=UNKNOWN
PartitionName=cpu Nodes=ALL Default=YES MaxTime=INFINITE State=UP
PartitionName=debug Nodes=ALL MaxTime=01:00:00 State=UP
EOF
mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm

# Containers often lack the v1 systemd cgroup hierarchy slurmd probes at start.
if [[ ! -d /sys/fs/cgroup/systemd ]] && [[ $(stat -fc %T /sys/fs/cgroup) != cgroup2fs ]]; then
    mkdir -p /sys/fs/cgroup/systemd
    mount -t cgroup -o none,name=systemd cgroup /sys/fs/cgroup/systemd || true
fi

pkill slurmctld 2>/dev/null || true; pkill slurmd 2>/dev/null || true; sleep 1
/usr/sbin/slurmctld && /usr/sbin/slurmd && sleep 3
sinfo

echo "== [4/6] hpcuser + sshd =="
id hpcuser >/dev/null 2>&1 || useradd -m -s /bin/bash hpcuser
sudo -u hpcuser bash -c '
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    [[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
    grep -qf ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys 2>/dev/null || \
        cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys'
[[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q
grep -qf /root/.ssh/id_ed25519.pub /home/hpcuser/.ssh/authorized_keys || \
    cat /root/.ssh/id_ed25519.pub >> /home/hpcuser/.ssh/authorized_keys
mkdir -p /run/sshd; ssh-keygen -A >/dev/null
pgrep -x sshd >/dev/null || /usr/sbin/sshd

# If this host reaches the internet via a TLS-intercepting egress proxy (root
# has HTTPS_PROXY set), propagate it to hpcuser and Slurm jobs: node bootstrap
# downloads (conda, pip) run as hpcuser and fail without it.
if [[ -n "${HTTPS_PROXY:-}" ]]; then
    echo "   propagating egress proxy ${HTTPS_PROXY} to hpcuser"
    for ca in /root/.ccr/agent-proxy-ca.crt; do
        [[ -f $ca ]] && cp "$ca" /usr/local/share/ca-certificates/ && update-ca-certificates >/dev/null
    done
    # TLS-intercepting proxies re-sign certificates: curl trusts the system
    # store, but uv (rustls, bundled roots) and pip (certifi) do NOT -- they
    # fail with "invalid peer certificate: UnknownIssuer" unless pointed at
    # the system bundle explicitly.
    CA=/etc/ssl/certs/ca-certificates.crt
    if ! grep -q HTTPS_PROXY /etc/environment 2>/dev/null; then
        {
            echo "https_proxy=${HTTPS_PROXY}"; echo "http_proxy=${HTTPS_PROXY}"
            echo "HTTPS_PROXY=${HTTPS_PROXY}"; echo "HTTP_PROXY=${HTTPS_PROXY}"
            echo "no_proxy=${no_proxy:-}"; echo "NO_PROXY=${NO_PROXY:-}"
            echo "SSL_CERT_FILE=${CA}"; echo "REQUESTS_CA_BUNDLE=${CA}"
            echo "PIP_CERT=${CA}"; echo "UV_NATIVE_TLS=true"
        } >> /etc/environment
    fi
    # Insert at the TOP of .bashrc: Ubuntu's stock .bashrc returns early for
    # non-interactive shells, so appended exports never reach batch jobs.
    if ! grep -q HTTPS_PROXY /home/hpcuser/.bashrc 2>/dev/null; then
        sed -i \
            -e "1i export https_proxy=${HTTPS_PROXY} http_proxy=${HTTPS_PROXY}" \
            -e "1i export HTTPS_PROXY=${HTTPS_PROXY} HTTP_PROXY=${HTTPS_PROXY}" \
            -e "1i export no_proxy='${no_proxy:-}' NO_PROXY='${NO_PROXY:-}'" \
            -e "1i export SSL_CERT_FILE=${CA} REQUESTS_CA_BUNDLE=${CA} PIP_CERT=${CA} UV_NATIVE_TLS=true CURL_CA_BUNDLE=${CA}" \
            /home/hpcuser/.bashrc
    fi
fi

echo "== [5/6] SkyPilot wiring =="
mkdir -p /root/.slurm /root/.sky
cat > /root/.slurm/config <<'EOF'
Host demo-hpc
    HostName localhost
    User hpcuser
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
if [[ ! -f /root/.sky/config.yaml ]] || ! grep -q "demo-hpc" /root/.sky/config.yaml; then
cat >> /root/.sky/config.yaml <<'EOF'
slurm:
  allowed_clusters:
    - demo-hpc
  provision_timeout: 600
  cluster_configs:
    demo-hpc:
      cpu_partition: cpu
EOF
fi

# Egress-restricted environments: SkyPilot's node bootstrap fetches uv from
# astral.sh. If that domain is blocked (e.g. policy proxy) but PyPI is allowed,
# pre-seed the uv binary where SkyPilot expects it and the curl is skipped.
# The per-cluster home is /home/hpcuser/.sky_clusters/<cluster>-<userhash[:8]>.
seed_uv_for_cluster() {
    local cluster=$1
    curl -fsSLI --max-time 10 https://astral.sh/uv/install.sh >/dev/null 2>&1 && return 0
    echo "   astral.sh unreachable -> seeding uv from PyPI for cluster '${cluster}'"
    local uhash
    uhash=$(cut -c1-8 ~/.sky/user_hash 2>/dev/null) || {
        echo "   ~/.sky/user_hash missing (run any sky command once), skipping"; return 0; }
    local fake_home=/home/hpcuser/.sky_clusters/${cluster}-${uhash}
    mkdir -p /tmp/uvwheel && pip download -q uv -d /tmp/uvwheel
    ( cd /tmp/uvwheel && unzip -o -q uv-*.whl '*/scripts/uv' -d /tmp/uvpkg )
    mkdir -p "${fake_home}/.local/bin"
    cp /tmp/uvpkg/uv-*/scripts/uv "${fake_home}/.local/bin/uv"
    chmod +x "${fake_home}/.local/bin/uv"
    chown -R hpcuser:hpcuser /home/hpcuser/.sky_clusters
}
seed_uv_for_cluster hpc-demo || true

echo "== [6/6] End-to-end smoke: SSH -> sbatch =="
ssh -o StrictHostKeyChecking=accept-new -F /root/.slurm/config demo-hpc \
    'sbatch --wrap="echo smoke-ok on \$(hostname)" -o /tmp/smoke.out >/dev/null && sleep 8 && cat /tmp/smoke.out'

echo
echo "Done. Next:"
echo "  sky api start   # if not already running"
echo "  sky check slurm"
echo "  sky launch -y -c hpc-demo --infra slurm/demo-hpc --cpus 2 -- hostname"
