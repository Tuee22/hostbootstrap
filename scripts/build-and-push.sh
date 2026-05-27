#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-basecontainer}"
CPU_BASE_IMAGE="${CPU_BASE_IMAGE:-ubuntu:24.04}"
BUILDER_NAME="${BUILDER_NAME:-basecontainer-builder}"
BUILDX_PROGRESS="${BUILDX_PROGRESS:-plain}"

resolve_latest_cuda_base_image() {
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "Set CUDA_BASE_IMAGE, or install curl and jq so the latest CUDA base can be resolved." >&2
    exit 1
  fi

  tags="$(
    url='https://hub.docker.com/v2/repositories/nvidia/cuda/tags?page_size=100&name=cudnn-devel-ubuntu24.04'
    while [ -n "${url}" ]; do
      page="$(curl -fsSL "${url}")"
      printf '%s\n' "${page}" | jq -r '.results[].name'
      url="$(printf '%s\n' "${page}" | jq -r '.next // empty')"
    done
  )"

  candidates="$(
    printf '%s\n' "${tags}" \
      | jq -R -s -r '
          split("\n")
          | map(select(test("^[0-9]+[.][0-9]+[.][0-9]+-cudnn-devel-ubuntu24[.]04$")))
          | sort_by(split("-")[0] | split(".") | map(tonumber))
          | reverse
          | .[]
        '
  )"

  while IFS= read -r tag; do
    if [ -z "${tag}" ]; then
      continue
    fi

    image="nvidia/cuda:${tag}"
    if docker buildx imagetools inspect --raw "${image}" \
      | jq -e '
          ([.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64")] | length > 0)
          and
          ([.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "arm64")] | length > 0)
        ' >/dev/null; then
      printf '%s\n' "${image}"
      return
    fi
  done <<< "${candidates}"

  echo "Unable to resolve a CUDA cuDNN devel Ubuntu 24.04 tag with amd64 and arm64 manifests." >&2
  exit 1
}

CUDA_BASE_IMAGE="${CUDA_BASE_IMAGE:-$(resolve_latest_cuda_base_image)}"

logged_in_user="$(
  docker info 2>/dev/null \
    | awk -F': ' '/Username:/ {print $2; exit}'
)"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-$logged_in_user}"

if [ -z "${DOCKERHUB_USERNAME}" ]; then
  echo "Docker Hub username not found. Run docker login or set DOCKERHUB_USERNAME." >&2
  exit 1
fi

IMAGE_REPO="docker.io/${DOCKERHUB_USERNAME}/${IMAGE_NAME}"

docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1 \
  || docker buildx create --name "${BUILDER_NAME}" --use
docker buildx use "${BUILDER_NAME}"

build_cpu_image() {
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg BASE_IMAGE="${CPU_BASE_IMAGE}" \
    --build-arg IMAGE_FLAVOR=cpu \
    --progress "${BUILDX_PROGRESS}" \
    --provenance=true \
    --sbom=true \
    --tag "${IMAGE_REPO}:cpu-ubuntu24.04" \
    --tag "${IMAGE_REPO}:ubuntu24.04" \
    --push \
    .
}

build_cuda_image() {
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg BASE_IMAGE="${CUDA_BASE_IMAGE}" \
    --build-arg IMAGE_FLAVOR=cuda \
    --progress "${BUILDX_PROGRESS}" \
    --provenance=true \
    --sbom=true \
    --tag "${IMAGE_REPO}:cuda-ubuntu24.04" \
    --tag "${IMAGE_REPO}:cuda" \
    --push \
    .
}

run_labeled() {
  label="$1"
  shift
  "$@" 2>&1 | awk -v label="${label}" '{ print "[" label "] " $0; fflush(); }'
}

cpu_pid=""
cuda_pid=""

terminate_builds() {
  echo "Stopping parallel builds..." >&2
  if [ -n "${cpu_pid}" ]; then
    kill "${cpu_pid}" 2>/dev/null || true
  fi
  if [ -n "${cuda_pid}" ]; then
    kill "${cuda_pid}" 2>/dev/null || true
  fi
  exit 130
}

trap terminate_builds INT TERM

echo "Starting CPU and CUDA builds in parallel for ${IMAGE_REPO}"
echo "CPU base: ${CPU_BASE_IMAGE}"
echo "CUDA base: ${CUDA_BASE_IMAGE}"

run_labeled cpu build_cpu_image &
cpu_pid="$!"
run_labeled cuda build_cuda_image &
cuda_pid="$!"

set +e
wait "${cpu_pid}"
cpu_status="$?"
wait "${cuda_pid}"
cuda_status="$?"
set -e

trap - INT TERM

if [ "${cpu_status}" -ne 0 ] || [ "${cuda_status}" -ne 0 ]; then
  echo "Build failure: cpu=${cpu_status}, cuda=${cuda_status}" >&2
  exit 1
fi

echo "CPU and CUDA builds completed successfully."
