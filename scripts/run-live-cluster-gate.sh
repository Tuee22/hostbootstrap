#!/bin/sh

set -eu

if [ "$(uname -s)" != "Linux" ]; then
    echo "phase-16 live cluster gate requires a Linux host" >&2
    exit 1
fi

for tool in docker grep kind kubectl timeout; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "phase-16 live cluster gate requires $tool" >&2
        exit 1
    fi
done

cluster_suffix="$(tr -d '-' </proc/sys/kernel/random/uuid | cut -c1-24)"
cluster_name="hostbootstrap-phase16-${cluster_suffix}"
kubeconfig="/tmp/${cluster_name}.kubeconfig"
durable_root="/tmp/${cluster_name}.durable"
created=0

cleanup() {
    if [ "$created" -eq 1 ]; then
        created=0
        timeout --signal=KILL 180s kind delete cluster --name "$cluster_name"
    fi
}

trap cleanup EXIT HUP INT TERM

timeout --signal=KILL 30s docker info >/dev/null
existing_clusters="$(timeout --signal=KILL 30s kind get clusters)"
if printf '%s\n' "$existing_clusters" | grep --fixed-strings --line-regexp --quiet "$cluster_name"; then
    echo "phase-16 live cluster gate refused the pre-existing cluster $cluster_name" >&2
    exit 1
fi
if [ -e "$kubeconfig" ]; then
    echo "phase-16 live cluster gate refused the pre-existing kubeconfig $kubeconfig" >&2
    exit 1
fi
mkdir "$durable_root"
printf '%s\n' "$cluster_name" >"${durable_root}/sentinel"
created=1
timeout --signal=KILL 180s kind create cluster --name "$cluster_name" --kubeconfig "$kubeconfig" --wait 180s
timeout --signal=KILL 180s kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready nodes --all --timeout=180s
timeout --signal=KILL 30s kubectl --kubeconfig "$kubeconfig" get nodes --output=name
timeout --signal=KILL 180s kind delete cluster --name "$cluster_name"

remaining_nodes="$(timeout --signal=KILL 30s docker ps --all --quiet --filter "label=io.x-k8s.kind.cluster=${cluster_name}")"
if [ -n "$remaining_nodes" ]; then
    echo "phase-16 live cluster gate left kind nodes behind" >&2
    exit 1
fi

if [ "$(cat "${durable_root}/sentinel")" != "$cluster_name" ]; then
    echo "phase-16 live cluster gate changed the durable-root sentinel" >&2
    exit 1
fi

created=0
echo "phase-16 live cluster gate passed for ${cluster_name} on $(uname -m) Linux"
