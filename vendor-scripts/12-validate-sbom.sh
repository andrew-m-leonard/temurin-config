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
# Temurin Vendor Implementation: 12-validate-sbom
#
# Validates SBOM (Software Bill of Materials) files produced during the Build
# stage. Clones temurin-build and delegates to tooling/validateSBOM.sh.
#
# Required Environment Variables:
#   WORKSPACE            - Stage workspace directory
#   CONFIG_FILE          - Path to pipeline-config.json
#   INPUT_ARTIFACTS_DIR  - Directory containing input artifacts from Build stage
#   TARGET_DIR           - Directory for this stage's output
#
# Optional Environment Variables:
#   JAVA_VERSION         - Java version (extracted from CONFIG_FILE if not set)
#   SCM_REF              - SCM reference (extracted from CONFIG_FILE if not set)
#
# Exit Codes:
#   0 - All SBOM files validated successfully
#   1 - Validation failed or no SBOM files found
################################################################################

# ---------------------------------------------------------------------------
# Resolve script directory to find shared lib utilities from ci-adoptium-pipelines
# PIPELINE_ROOT: set by CI pipelines where WORKSPACE is not the location of
#   the ci-adoptium-pipelines repo. Falls back to WORKSPACE if not set.
# ---------------------------------------------------------------------------
PIPELINE_LIB="${PIPELINE_ROOT:-${WORKSPACE}}/scripts/lib"
source "${PIPELINE_LIB}/config-utils.sh"

echo "=== Temurin SBOM Validation Stage ==="

# Validate required environment variables
: "${WORKSPACE:?WORKSPACE environment variable is not set}"
: "${CONFIG_FILE:?CONFIG_FILE environment variable is not set}"
: "${INPUT_ARTIFACTS_DIR:?INPUT_ARTIFACTS_DIR environment variable is not set}"
: "${TARGET_DIR:?TARGET_DIR environment variable is not set}"

# Read temurin-build repo and branch from pipeline-config.json.
# BUILD_REF stage param takes precedence; fall back to the repo default
# from pipeline-config.json (.repoDefaults.buildRef), then hard-coded 'master'.
TEMURIN_BUILD_REPO=$(get_config_value "${CONFIG_FILE}" ".repoDefaults.buildRepoUrl")
CONFIG_BUILD_REF=$(get_config_value "${CONFIG_FILE}" ".repoDefaults.buildRef")
BUILD_REF_SOURCE="default"; [[ -n "${BUILD_REF:-}" ]] && BUILD_REF_SOURCE="param"
TEMURIN_BUILD_BRANCH="${BUILD_REF:-${CONFIG_BUILD_REF:-master}}"
TEMURIN_BUILD_DIR="${WORKSPACE}/temurin-build-sbom-validation"

echo "  Build Repo URL : ${TEMURIN_BUILD_REPO} (default)"
echo "  Build Ref      : ${TEMURIN_BUILD_BRANCH} (${BUILD_REF_SOURCE})"

# Clone temurin-build repository if not already present
if [ ! -d "${TEMURIN_BUILD_DIR}" ]; then
    echo "Cloning temurin-build repository..."
    git clone --depth 1 --branch "${TEMURIN_BUILD_BRANCH}" "${TEMURIN_BUILD_REPO}" "${TEMURIN_BUILD_DIR}"
else
    echo "Using existing temurin-build repository at ${TEMURIN_BUILD_DIR}"
fi

# Verify validateSBOM.sh exists
VALIDATE_SBOM_SCRIPT="${TEMURIN_BUILD_DIR}/tooling/validateSBOM.sh"
if [ ! -f "${VALIDATE_SBOM_SCRIPT}" ]; then
    echo "ERROR: validateSBOM.sh not found at ${VALIDATE_SBOM_SCRIPT}"
    exit 1
fi

# Extract configuration if not provided via environment
if [ -z "${JAVA_VERSION:-}" ]; then
    JAVA_VERSION=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}'))['buildConfig']['JAVA_TO_BUILD'])")
    echo "Extracted JAVA_VERSION from config: ${JAVA_VERSION}"
fi

# Extract numeric version for validateSBOM.sh (e.g., "jdk21u" -> "21")
JDK_NUMERIC_VERSION=$(echo "${JAVA_VERSION}" | sed 's/[^0-9]//g')
echo "Extracted numeric JDK version: ${JDK_NUMERIC_VERSION}"

if [ -z "${SCM_REF:-}" ]; then
    SCM_REF=$(python3 -c "import json; config=json.load(open('${CONFIG_FILE}')); print(config.get('refs', {}).get('scmRef', 'HEAD'))")
    echo "Extracted SCM_REF from config: ${SCM_REF}"
fi

# Find all SBOM JSON files (excluding metadata files and params files)
echo "Searching for SBOM files in ${INPUT_ARTIFACTS_DIR}..."
SBOM_FILES=$(find "${INPUT_ARTIFACTS_DIR}" -name '*sbom*.json' -type f ! -name '*.params.json' | grep -v metadata || true)

if [ -z "${SBOM_FILES}" ]; then
    echo "WARNING: No SBOM files found in ${INPUT_ARTIFACTS_DIR}"
    echo "This may indicate that SBOM generation was not successful"
    exit 1
fi

echo "Found SBOM files:"
echo "${SBOM_FILES}"

# Validate each SBOM file
VALIDATION_FAILED=0
while IFS= read -r sbom_file; do
    if [ -n "${sbom_file}" ]; then
        echo ""
        echo "Validating SBOM: ${sbom_file}"

        if bash "${VALIDATE_SBOM_SCRIPT}" \
            "${JDK_NUMERIC_VERSION}" \
            "${SCM_REF}" \
            "${sbom_file}"; then
            echo "SUCCESS: SBOM validation passed for ${sbom_file}"
        else
            echo "ERROR: SBOM validation failed for ${sbom_file}"
            VALIDATION_FAILED=1
        fi
    fi
done <<< "${SBOM_FILES}"

if [ ${VALIDATION_FAILED} -eq 1 ]; then
    echo ""
    echo "=== Temurin SBOM Validation Failed ==="
    exit 1
fi

echo ""
echo "=== Temurin SBOM Validation Complete ==="
exit 0
