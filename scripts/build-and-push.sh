#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build-and-push.sh [--amd64] [--arm64] [--all] [-h|--help]

Builds and pushes the CPU and CUDA images.

Platform selection (default: both amd64 and arm64):
  --amd64     Build only linux/amd64
  --arm64     Build only linux/arm64
  --all       Build both linux/amd64 and linux/arm64 (default)
  -h, --help  Show this help message

--amd64 and --arm64 may be combined to build both.
EOF
}

want_amd64=false
want_arm64=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --amd64) want_amd64=true ;;
    --arm64) want_arm64=true ;;
    --all) want_amd64=true; want_arm64=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [ "${want_amd64}" = false ] && [ "${want_arm64}" = false ]; then
  want_amd64=true
  want_arm64=true
fi

platforms_list=()
if [ "${want_amd64}" = true ]; then
  platforms_list+=("linux/amd64")
fi
if [ "${want_arm64}" = true ]; then
  platforms_list+=("linux/arm64")
fi
PLATFORMS="$(IFS=,; echo "${platforms_list[*]}")"

IMAGE_NAME="${IMAGE_NAME:-basecontainer}"
CPU_BASE_IMAGE="${CPU_BASE_IMAGE:-ubuntu:24.04}"
BUILDER_NAME="${BUILDER_NAME:-basecontainer-builder}"
BUILDX_PROGRESS="${BUILDX_PROGRESS:-plain}"
BUILDKIT_MAX_PARALLELISM="${BUILDKIT_MAX_PARALLELISM:-1}"

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

ensure_builder() {
  buildkitd_flags="--allow-insecure-entitlement=network.host --oci-max-parallelism=${BUILDKIT_MAX_PARALLELISM}"

  if docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
    current_flags="$(docker buildx inspect "${BUILDER_NAME}" | awk -F': ' '/BuildKit daemon flags:/ {print $2; exit}')"
    if [[ " ${current_flags} " != *" --oci-max-parallelism=${BUILDKIT_MAX_PARALLELISM} "* ]]; then
      echo "Recreating builder ${BUILDER_NAME} with BuildKit max parallelism ${BUILDKIT_MAX_PARALLELISM}."
      docker buildx rm --keep-state --force "${BUILDER_NAME}" >/dev/null
      docker buildx create \
        --name "${BUILDER_NAME}" \
        --driver docker-container \
        --buildkitd-flags "${buildkitd_flags}" \
        --use \
        >/dev/null
    else
      docker buildx use "${BUILDER_NAME}"
    fi
  else
    docker buildx create \
      --name "${BUILDER_NAME}" \
      --driver docker-container \
      --buildkitd-flags "${buildkitd_flags}" \
      --use \
      >/dev/null
  fi

  docker buildx inspect --bootstrap "${BUILDER_NAME}" >/dev/null
}

ensure_builder

build_cpu_image() {
  docker buildx build \
    --platform "${PLATFORMS}" \
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
    --platform "${PLATFORMS}" \
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
echo "Platforms: ${PLATFORMS}"
echo "CPU base: ${CPU_BASE_IMAGE}"
echo "CUDA base: ${CUDA_BASE_IMAGE}"
echo "BuildKit max parallelism: ${BUILDKIT_MAX_PARALLELISM}"

run_labeled cpu build_cpu_image &
cpu_pid="$!"
run_labeled cuda build_cuda_image &
cuda_pid="$!"

set +e
cpu_status=""
cuda_status=""

while [ -z "${cpu_status}" ] || [ -z "${cuda_status}" ]; do
  if [ -z "${cpu_status}" ] && ! kill -0 "${cpu_pid}" 2>/dev/null; then
    wait "${cpu_pid}"
    cpu_status="$?"
    if [ "${cpu_status}" -ne 0 ] && [ -z "${cuda_status}" ]; then
      echo "CPU build failed; stopping CUDA build..." >&2
      kill "${cuda_pid}" 2>/dev/null || true
      wait "${cuda_pid}"
      cuda_status="$?"
      break
    fi
  fi

  if [ -z "${cuda_status}" ] && ! kill -0 "${cuda_pid}" 2>/dev/null; then
    wait "${cuda_pid}"
    cuda_status="$?"
    if [ "${cuda_status}" -ne 0 ] && [ -z "${cpu_status}" ]; then
      echo "CUDA build failed; stopping CPU build..." >&2
      kill "${cpu_pid}" 2>/dev/null || true
      wait "${cpu_pid}"
      cpu_status="$?"
      break
    fi
  fi

  sleep 2
done
set -e

trap - INT TERM

if [ "${cpu_status}" -ne 0 ] || [ "${cuda_status}" -ne 0 ]; then
  echo "Build failure: cpu=${cpu_status}, cuda=${cuda_status}" >&2
  exit 1
fi

echo "CPU and CUDA builds completed successfully."
