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
# Temurin Smoke Tests - AQA functional/buildAndPackage tests
#
# Runs the Adoptium aqa-tests extended.functional suite using the
# temurin-build functional tests against the freshly built JDK.
#
# Required Environment Variables (set by initializeStage):
#   WORKSPACE             - Stage workspace directory
#   CONFIG_FILE           - Path to pipeline-config.json
#   INPUT_ARTIFACTS_DIR   - Directory containing the built JDK artifact(s)
#   BUILD_NUMBER          - Build number
#
# Stage-specific Environment Variables:
#   TARGET_DIR            - Directory for test results output

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script directory to find shared lib utilities from ci-adoptium-pipelines
# PIPELINE_ROOT: set by CI pipelines where WORKSPACE is not the location of
#   the ci-adoptium-pipelines repo. Falls back to WORKSPACE if not set.
# ---------------------------------------------------------------------------
PIPELINE_LIB="${PIPELINE_ROOT:-${WORKSPACE}}/scripts/lib"
source "${PIPELINE_LIB}/logging-utils.sh"
source "${PIPELINE_LIB}/config-utils.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
STAGE_NAME="smoke-tests"
BUILD_NUMBER="${BUILD_NUMBER:-local}"
TEMURIN_FUNCTIONAL_DIR="/test/functional"
BUILD_LIST="functional/buildAndPackage"
TARGET_SUITE="extended.functional"

main() {
    log_section "Temurin Smoke Tests (AQA ${TARGET_SUITE}) - Start"

    # -----------------------------------------------------------------------
    # Read build config
    # -----------------------------------------------------------------------
    local java_version
    local target_os
    local architecture
    local aqa_ref
    local aqa_repo_url
    local build_ref
    local build_repo_url
    java_version=$(get_config_value "${CONFIG_FILE}" ".buildConfig.JAVA_TO_BUILD")
    target_os=$(get_config_value "${CONFIG_FILE}" ".buildConfig.TARGET_OS")
    architecture=$(get_config_value "${CONFIG_FILE}" ".buildConfig.ARCHITECTURE")
    aqa_ref=$(get_config_value "${CONFIG_FILE}" ".repoDefaults.aqaRef")
    aqa_repo_url=$(get_config_value "${CONFIG_FILE}" ".repoDefaults.aqaRepoUrl")
    build_ref=$(get_config_value "${CONFIG_FILE}" ".repoDefaults.buildRef")
    build_repo_url=$(get_config_value "${CONFIG_FILE}" ".repoDefaults.buildRepoUrl")

    # Stage params take precedence; fall back to the repo defaults from
    # pipeline-config.json, then hard-coded 'master'.
    local aqa_tests_repo="${aqa_repo_url}"
    local aqa_tests_branch; aqa_tests_branch="${AQA_REF:-${aqa_ref:-master}}"
    local aqa_ref_source="default"; [[ -n "${AQA_REF:-}" ]] && aqa_ref_source="param"
    local temurin_build_repo="${build_repo_url}"
    local temurin_build_branch; temurin_build_branch="${BUILD_REF:-${build_ref:-master}}"
    local build_ref_source="default"; [[ -n "${BUILD_REF:-}" ]] && build_ref_source="param"

    log_info "Test Configuration:"
    log_info "  Java Version     : ${java_version}"
    log_info "  Target OS        : ${target_os}"
    log_info "  Architecture     : ${architecture}"
    log_info "  AQA Suite        : ${BUILD_LIST} / ${TARGET_SUITE}"
    log_info "  AQA Repo         : ${aqa_tests_repo} (default)"
    log_info "  AQA Ref          : ${aqa_tests_branch} (${aqa_ref_source})"
    log_info "  Temurin Build    : ${temurin_build_repo} (default)"
    log_info "  Temurin Build Ref: ${temurin_build_branch} (${build_ref_source})"

    # -----------------------------------------------------------------------
    # Locate and extract the JDK artifact
    # -----------------------------------------------------------------------
    local jdk_artifact
    jdk_artifact=$(find_jdk_artifact)
    log_info "JDK artifact : ${jdk_artifact}"

    local jdk_extract_dir="${WORKSPACE}/jdk-smoke-extract"
    local test_jdk_home
    test_jdk_home=$(extract_jdk "${jdk_artifact}" "${jdk_extract_dir}" "${target_os}")
    log_info "TEST_JDK_HOME : ${test_jdk_home}"

    # -----------------------------------------------------------------------
    # Clone aqa-tests
    # -----------------------------------------------------------------------
    local aqa_dir="${WORKSPACE}/aqa-tests"
    if [[ -d "${aqa_dir}" ]]; then
        log_error "aqa-tests directory already exists: ${aqa_dir}"
        log_error "Cannot guarantee its contents — aborting. Remove it and retry."
        exit 1
    fi
    log_info "Cloning aqa-tests from ${aqa_tests_repo} @ ${aqa_tests_branch} ..."
    git clone --depth 1 --branch "${aqa_tests_branch}" "${aqa_tests_repo}" "${aqa_dir}"

    # -----------------------------------------------------------------------
    # Run get.sh to pull in temurin-build functional tests
    # -----------------------------------------------------------------------
    log_section "Running aqa-tests get.sh"
    cd "${aqa_dir}"
    bash get.sh \
        --vendor_repos "${temurin_build_repo}" \
        --vendor_branches "${temurin_build_branch}" \
        --vendor_dirs "${TEMURIN_FUNCTIONAL_DIR}" \
        --clone_openj9 true

    # -----------------------------------------------------------------------
    # Compile and run the test suite
    # -----------------------------------------------------------------------
    log_section "Compiling TKG test suite"
    cd "${aqa_dir}/TKG"

    export BUILD_LIST="${BUILD_LIST}"
    export TEST_JDK_HOME="${test_jdk_home}"

    make compile

    log_section "Running ${TARGET_SUITE}"
    local test_exit_code=0
    make "_${TARGET_SUITE}" || test_exit_code=$?

    # -----------------------------------------------------------------------
    # Collect results
    # -----------------------------------------------------------------------
    log_section "Collecting test results"
    collect_results "${aqa_dir}" "${test_exit_code}"

    if [[ ${test_exit_code} -eq 0 ]]; then
        log_section "Temurin Smoke Tests - PASSED"
    else
        log_section "Temurin Smoke Tests - FAILED (exit code: ${test_exit_code})"
    fi

    exit ${test_exit_code}
}

# ---------------------------------------------------------------------------
# Find the main JDK image tarball/zip in INPUT_ARTIFACTS_DIR
# ---------------------------------------------------------------------------
find_jdk_artifact() {
    # Prefer the JDK image (pattern: *jdk_*.tar.gz or *jdk_*.zip)
    # Exclude jre/testimage/debugimage/static-libs variants
    local artifact
    artifact=$(find "${INPUT_ARTIFACTS_DIR}" \
        \( -name "*jdk_*.tar.gz" -o -name "*jdk_*.zip" \) \
        ! -name "*jre_*" \
        ! -name "*testimage*" \
        ! -name "*debugimage*" \
        ! -name "*static-libs*" \
        | sort | head -n 1)

    if [[ -z "${artifact}" ]]; then
        log_error "No JDK image artifact found in ${INPUT_ARTIFACTS_DIR}"
        log_error "Expected pattern: *jdk_*.tar.gz or *jdk_*.zip"
        log_error "Available files:"
        find "${INPUT_ARTIFACTS_DIR}" \( -name "*.tar.gz" -o -name "*.zip" \) \
            -exec basename {} \; 2>/dev/null || true
        exit 1
    fi

    echo "${artifact}"
}

# ---------------------------------------------------------------------------
# Extract the JDK artifact and return the JAVA_HOME path
# ---------------------------------------------------------------------------
extract_jdk() {
    local artifact="$1"
    local extract_dir="$2"
    local target_os="$3"

    log_info "Extracting $(basename "${artifact}") to ${extract_dir}"
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"

    if [[ "${artifact}" == *.tar.gz ]]; then
        tar -xzf "${artifact}" -C "${extract_dir}"
    elif [[ "${artifact}" == *.zip ]]; then
        unzip -q "${artifact}" -d "${extract_dir}"
    else
        log_error "Unsupported archive format: ${artifact}"
        exit 1
    fi

    # The tarball expands to a single top-level directory
    local top_dir
    top_dir=$(find "${extract_dir}" -maxdepth 1 -mindepth 1 -type d | head -n 1)

    if [[ -z "${top_dir}" ]]; then
        log_error "Could not find extracted JDK directory under ${extract_dir}"
        exit 1
    fi

    # macOS JDKs nest the home under Contents/Home
    if [[ "${target_os}" == "mac" && -d "${top_dir}/Contents/Home" ]]; then
        echo "${top_dir}/Contents/Home"
    else
        echo "${top_dir}"
    fi
}

# ---------------------------------------------------------------------------
# Copy TKG output and any XML/HTML reports to TARGET_DIR
# ---------------------------------------------------------------------------
collect_results() {
    local aqa_dir="$1"
    local test_exit_code="$2"

    mkdir -p "${TARGET_DIR}"

    # TKG writes results under TKG/output/
    local tkg_output="${aqa_dir}/TKG/output"
    if [[ -d "${tkg_output}" ]]; then
        cp -r "${tkg_output}/." "${TARGET_DIR}/"
        log_info "TKG results copied to ${TARGET_DIR}"
    else
        log_warn "TKG output directory not found: ${tkg_output}"
    fi

    # Write a simple summary JSON
    cat > "${TARGET_DIR}/smoke-test-summary.json" <<EOF
{
  "stage": "${STAGE_NAME}",
  "buildList": "${BUILD_LIST}",
  "targetSuite": "${TARGET_SUITE}",
  "status": $([ "${test_exit_code}" -eq 0 ] && echo '"passed"' || echo '"failed"'),
  "exitCode": ${test_exit_code},
  "timestamp": $(date +%s),
  "timestampISO": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "buildNumber": "${BUILD_NUMBER}"
}
EOF

    log_info "Summary written to ${TARGET_DIR}/smoke-test-summary.json"
}

# ---------------------------------------------------------------------------
# Error trap
# ---------------------------------------------------------------------------
error_handler() {
    log_error "Smoke test stage failed at line $1"
    exit 1
}
trap 'error_handler ${LINENO}' ERR

main "$@"
