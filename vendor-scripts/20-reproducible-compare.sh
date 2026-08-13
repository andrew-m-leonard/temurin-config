#!/bin/bash
################################################################################
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################
set -euo pipefail

################################################################################
# Temurin Vendor Implementation: 20-reproducible-compare
#
# Compares a locally built JDK against the published Adoptium production binary
# for the same version to verify reproducibility. Clones temurin-build and
# delegates to tooling/reproducible/repro_compare.sh.
#
# Required Environment Variables:
#   WORKSPACE            - Stage workspace directory
#   CONFIG_FILE          - Path to pipeline-config.json
#   INPUT_ARTIFACTS_DIR  - Directory containing input artifacts from previous stage
#   TARGET_DIR           - Directory for this stage's output
#   RELEASE_TYPE         - Build type: RELEASE or NIGHTLY (default: NIGHTLY)
#
# Stage Parameters (set by the pipeline from params.json):
#   SCM_REF              - Git tag/ref identifying the version to compare (mandatory, no default)
#   BUILD_REF            - Git branch/tag for temurin-build (optional, falls back to pipeline-config.json)
#
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities from ci-adoptium-pipelines (resolved via PIPELINE_ROOT)
source "${PIPELINE_ROOT}/scripts/lib/logging-utils.sh"
source "${PIPELINE_ROOT}/scripts/lib/config-utils.sh"

log_section "Stage 20: Temurin Reproducible Build Comparison"

# Validate standard environment (WORKSPACE, CONFIG_FILE, TARGET_DIR)
validate_standard_environment

# Derive RELEASE boolean from RELEASE_TYPE (consistent with 02-build.sh)
RELEASE="$([[ "${RELEASE_TYPE:-NIGHTLY}" == "RELEASE" ]] && echo "true" || echo "false")"

# SCM_REF must be explicitly provided — there is no meaningful default for this
# stage. An empty value means we don't know what version to compare against.
if [[ -z "${SCM_REF:-}" ]]; then
    log_error "SCM_REF is not set or empty."
    log_error "This stage requires a specific Git tag/ref (e.g. jdk-21.0.2+13) to"
    log_error "identify the published Adoptium binary to compare against."
    log_error "Set SCM_REF via the stage parameter before triggering this stage."
    exit 1
fi

# Extract configuration values
VARIANT=$(get_config_value "${CONFIG_FILE}" ".buildConfig.VARIANT")
TARGET_OS=$(get_config_value "${CONFIG_FILE}" ".buildConfig.TARGET_OS")
ARCHITECTURE=$(get_config_value "${CONFIG_FILE}" ".buildConfig.ARCHITECTURE")
JAVA_TO_BUILD=$(get_config_value "${CONFIG_FILE}" ".buildConfig.JAVA_TO_BUILD")

# BUILD_REF stage param takes precedence; fall back to the repo default
# from pipeline-config.json (.repoDefaults.buildRef), then hard-coded 'master'.
BUILD_REPO_URL=$(get_config_value "${CONFIG_FILE}" ".repoDefaults.buildRepoUrl")
CONFIG_BUILD_REF=$(get_config_value "${CONFIG_FILE}" ".repoDefaults.buildRef")
BUILD_REF_SOURCE="default"; [[ -n "${BUILD_REF:-}" ]] && BUILD_REF_SOURCE="param"
BUILD_REF="${BUILD_REF:-${CONFIG_BUILD_REF:-master}}"

log_info "Configuration:"
log_info "  Variant: ${VARIANT}"
log_info "  Target OS: ${TARGET_OS}"
log_info "  Architecture: ${ARCHITECTURE}"
log_info "  Java Version: ${JAVA_TO_BUILD}"
log_info "  SCM Ref: ${SCM_REF}"
log_info "  Release: ${RELEASE}"
log_info "  Build Repo URL: ${BUILD_REPO_URL} (default)"
log_info "  Build Ref: ${BUILD_REF} (${BUILD_REF_SOURCE})"

# Create temporary workspace directories
COMPARE_WORKSPACE="${WORKSPACE}/reproducible-compare"
JDK_UPSTREAM="${COMPARE_WORKSPACE}/jdk-upstream"
JDK_BUILT="${COMPARE_WORKSPACE}/jdk-built"
TEMURIN_BUILD_DIR="${COMPARE_WORKSPACE}/temurin-build"

log_info "  Creating comparison workspace: ${COMPARE_WORKSPACE}"
mkdir -p "${JDK_UPSTREAM}" "${JDK_BUILT}"

################################################################################
# Step 1: Clone temurin-build repository
################################################################################

log_section "Cloning temurin-build repository"

log_info "Cloning temurin-build from ${BUILD_REPO_URL} (branch: ${BUILD_REF})"
git clone --branch "${BUILD_REF}" --depth 1 "${BUILD_REPO_URL}" "${TEMURIN_BUILD_DIR}"

REPRO_COMPARE_SCRIPT="${TEMURIN_BUILD_DIR}/tooling/reproducible/repro_compare.sh"

if [ ! -f "${REPRO_COMPARE_SCRIPT}" ]; then
    log_error "repro_compare.sh not found at: ${REPRO_COMPARE_SCRIPT}"
    exit 1
fi

log_info "temurin-build cloned successfully"

################################################################################
# Step 2: Prepare API parameters
################################################################################

log_section "Preparing Adoptium API parameters"

# Remove "_adopt" suffix from SCM_REF if present
SCM_REF_FOR_API="${SCM_REF/_adopt/}"
log_info "SCM_REF_FOR_API: ${SCM_REF_FOR_API}"

# Add "-ea-beta" suffix for EA builds
if [ "${RELEASE}" = "false" ]; then
    SCM_REF_FOR_API="${SCM_REF_FOR_API}-ea-beta"
    log_info "EA build detected, using: ${SCM_REF_FOR_API}"
fi

# Map OS and ARCH to Adoptium API format
case "${TARGET_OS}" in
    mac)     API_OS="mac" ;;
    linux)   API_OS="linux" ;;
    windows) API_OS="windows" ;;
    aix)     API_OS="aix" ;;
    *) log_error "Unsupported OS: ${TARGET_OS}"; exit 1 ;;
esac

# Map TARGET_OS to uname-style OS name for repro_compare.sh
case "${TARGET_OS}" in
    mac)     REPRO_OS="Darwin" ;;
    linux)   REPRO_OS="Linux" ;;
    windows) REPRO_OS="CYGWIN" ;;
    aix)     REPRO_OS="AIX" ;;
    *) log_error "Unsupported OS for repro_compare: ${TARGET_OS}"; exit 1 ;;
esac

case "${ARCHITECTURE}" in
    aarch64) API_ARCH="aarch64" ;;
    x64)     API_ARCH="x64" ;;
    x32)     API_ARCH="x32" ;;
    ppc64)   API_ARCH="ppc64" ;;
    ppc64le) API_ARCH="ppc64le" ;;
    s390x)   API_ARCH="s390x" ;;
    *) log_error "Unsupported architecture: ${ARCHITECTURE}"; exit 1 ;;
esac

# Construct API URLs
API_JDK_URL="https://api.adoptium.net/v3/binary/version/${SCM_REF_FOR_API}/${API_OS}/${API_ARCH}/jdk/hotspot/normal/eclipse?project=jdk"
API_SBOM_URL="https://api.adoptium.net/v3/binary/version/${SCM_REF_FOR_API}/${API_OS}/${API_ARCH}/sbom/hotspot/normal/eclipse?project=jdk"

log_info "API URLs:"
log_info "  JDK:  ${API_JDK_URL}"
log_info "  SBOM: ${API_SBOM_URL}"

################################################################################
# Step 3: Download production binaries
################################################################################

log_section "Downloading production binaries from Adoptium API"

# Determine file extension based on OS
case "${TARGET_OS}" in
    windows) JDK_EXT="zip" ;;
    *) JDK_EXT="tar.gz" ;;
esac

UPSTREAM_JDK_FILE="${COMPARE_WORKSPACE}/upstream-jdk.${JDK_EXT}"
UPSTREAM_SBOM_FILE="${COMPARE_WORKSPACE}/upstream-sbom.json"

log_info "Downloading JDK binary..."
if ! curl -L -f -o "${UPSTREAM_JDK_FILE}" "${API_JDK_URL}"; then
    log_error "Failed to download JDK from Adoptium API"
    log_error "URL: ${API_JDK_URL}"
    log_error "This may indicate the build is not yet published or the version string is incorrect"
    exit 1
fi
log_info "JDK binary downloaded: ${UPSTREAM_JDK_FILE}"

log_info "Downloading SBOM..."
if ! curl -L -f -o "${UPSTREAM_SBOM_FILE}" "${API_SBOM_URL}"; then
    log_warn "Failed to download SBOM (may not be available for this version)"
else
    log_info "SBOM downloaded: ${UPSTREAM_SBOM_FILE}"
fi

################################################################################
# Step 4: Unpack binaries
################################################################################

log_section "Unpacking binaries for comparison"

log_info "Unpacking upstream JDK to: ${JDK_UPSTREAM}"
cd "${JDK_UPSTREAM}"
case "${JDK_EXT}" in
    tar.gz) tar -xzf "${UPSTREAM_JDK_FILE}" ;;
    zip)    unzip -q "${UPSTREAM_JDK_FILE}" ;;
esac
log_info "Upstream JDK unpacked"

# Find the locally built JDK in INPUT_ARTIFACTS_DIR
log_info "Finding locally built JDK in: ${INPUT_ARTIFACTS_DIR}"
BUILT_JDK_FILE=$(find "${INPUT_ARTIFACTS_DIR}" -name "OpenJDK*-jdk_*.${JDK_EXT}" | grep -v "sources\|debugimage\|testimage\|static-libs\|jre" | head -n 1)

if [ -z "${BUILT_JDK_FILE}" ]; then
    log_error "No locally built JDK found in ${INPUT_ARTIFACTS_DIR}"
    log_error "Expected pattern: OpenJDK*-jdk_*.${JDK_EXT}"
    log_error "Files found in ${INPUT_ARTIFACTS_DIR}:"
    ls -la "${INPUT_ARTIFACTS_DIR}"
    exit 1
fi

log_info "Found locally built JDK: ${BUILT_JDK_FILE}"

log_info "Unpacking locally built JDK to: ${JDK_BUILT}"
cd "${JDK_BUILT}"
case "${JDK_EXT}" in
    tar.gz) tar -xzf "${BUILT_JDK_FILE}" ;;
    zip)    unzip -q "${BUILT_JDK_FILE}" ;;
esac
log_info "Locally built JDK unpacked"

################################################################################
# Step 5: Run reproducible comparison
################################################################################

log_section "Running reproducible build comparison"

log_info "Searching for JDK directories..."
UPSTREAM_JDK_DIR=$(find "${JDK_UPSTREAM}" -mindepth 1 -maxdepth 2 -type d \( -name "jdk-*" -o -name "jdk*" \) | head -n 1)
BUILT_JDK_DIR=$(find "${JDK_BUILT}"    -mindepth 1 -maxdepth 2 -type d \( -name "jdk-*" -o -name "jdk*" \) | head -n 1)

if [ -z "${UPSTREAM_JDK_DIR}" ]; then
    log_error "Could not find unpacked upstream JDK directory in ${JDK_UPSTREAM}"
    ls -la "${JDK_UPSTREAM}"
    exit 1
fi
if [ -z "${BUILT_JDK_DIR}" ]; then
    log_error "Could not find unpacked built JDK directory in ${JDK_BUILT}"
    ls -la "${JDK_BUILT}"
    exit 1
fi

log_info "Comparison directories:"
log_info "  Upstream: ${UPSTREAM_JDK_DIR}"
log_info "  Built:    ${BUILT_JDK_DIR}"

COMPARE_OUTPUT="${COMPARE_WORKSPACE}/comparison-report.txt"
COMPARE_EXIT_CODE=0
cd "${COMPARE_WORKSPACE}"

if bash "${REPRO_COMPARE_SCRIPT}" "${VARIANT}" "${UPSTREAM_JDK_DIR}" "${VARIANT}" "${BUILT_JDK_DIR}" "${REPRO_OS}" | tee "${COMPARE_OUTPUT}"; then
    log_info "SUCCESS: Build is 100% reproducible"
    if [ -f "${COMPARE_WORKSPACE}/ReproduciblePercent" ]; then
        PERCENT=$(cat "${COMPARE_WORKSPACE}/ReproduciblePercent" | tr -d '[:space:]')
        log_info "Reproducibility: ${PERCENT}%"
    fi
else
    COMPARE_EXIT_CODE=$?
    log_error "WARNING: Reproducible build comparison FAILED (exit code: ${COMPARE_EXIT_CODE})"
    [ -f "${COMPARE_OUTPUT}" ] && cat "${COMPARE_OUTPUT}"
    [ -f "${COMPARE_WORKSPACE}/reprotest.diff" ] && cat "${COMPARE_WORKSPACE}/reprotest.diff"
fi

################################################################################
# Copy results to TARGET_DIR (always, so artifacts are archived on failure too)
################################################################################

log_section "Copying comparison results to TARGET_DIR"
mkdir -p "${TARGET_DIR}"

[ -f "${COMPARE_OUTPUT}" ] && cp "${COMPARE_OUTPUT}" "${TARGET_DIR}/comparison-report.txt" \
    && log_info "Copied: comparison-report.txt"
[ -f "${COMPARE_WORKSPACE}/ReproduciblePercent" ] && cp "${COMPARE_WORKSPACE}/ReproduciblePercent" "${TARGET_DIR}/ReproduciblePercent" \
    && log_info "Copied: ReproduciblePercent"
[ -f "${COMPARE_WORKSPACE}/reprotest.diff" ] && cp "${COMPARE_WORKSPACE}/reprotest.diff" "${TARGET_DIR}/reprotest.diff" \
    && log_info "Copied: reprotest.diff"

log_info "Stage 20: Temurin Reproducible Build Comparison - Complete"
exit ${COMPARE_EXIT_CODE}
