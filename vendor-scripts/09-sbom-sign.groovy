/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * Temurin Vendor Implementation: 09-sbom-sign
 *
 * JSF-signs the SBOM by triggering the downstream sign_temurin_jsf job and
 * copying the resulting signed SBOM JSON files back into TARGET_DIR for
 * archiving.  Must run before 10-digital-artifact-sign so the signed SBOM is
 * included in the set of artifacts that receive a detached GPG signature.
 *
 * Equivalent to the legacy jsfSignSBOM() function in openjdk_build_pipeline.groovy.
 *
 * Gate conditions (enforced by stageCondition in 09-sbom-sign.params.json):
 *   - SIGN_ARTIFACTS must be true
 *   - CREATE_SBOM    must be true
 *
 * Environment Variables (set by StageScriptRunner.run() via withEnv):
 *   WORKSPACE            - Stage workspace directory
 *   CONFIG_FILE          - Path to pipeline-config.json
 *   INPUT_ARTIFACTS_DIR  - Directory containing SBOM files to sign
 *   TARGET_DIR           - Directory for JSF-signed SBOM output
 *
 * Called by StageScriptRunner._dispatch():
 *   def script = load(found.path)
 *   exitCode = script(config) ?: EXIT_SUCCESS
 */

/**
 * Entry point called by StageScriptRunner._dispatch():
 *   def script = load(found.path)
 *   exitCode = script(config) ?: EXIT_SUCCESS
 */
int call(Map config) {

    // ── Gate check ────────────────────────────────────────────────────────────
    String signArtifacts = env.SIGN_ARTIFACTS ?: ''
    String createSbom    = env.CREATE_SBOM    ?: ''

    if (signArtifacts.toLowerCase() != 'true') {
        echo "ℹ️  09-sbom-sign: SIGN_ARTIFACTS='${signArtifacts}' is not true — skipping"
        return 0
    }
    if (createSbom.toLowerCase() != 'true') {
        echo "ℹ️  09-sbom-sign: CREATE_SBOM='${createSbom}' is not true — skipping"
        return 0
    }

    echo "=== Temurin SBOM Sign Stage ==="
    echo "  UPSTREAM_JOB_NAME  : ${env.JOB_NAME}"
    echo "  UPSTREAM_JOB_NUMBER: ${env.BUILD_NUMBER}"
    echo "  TARGET_DIR         : ${env.TARGET_DIR}"

    // ── Build SBOM signing libraries ──────────────────────────────────────────
    echo "Building SBOM signing libraries (build_sign_sbom_libraries)..."
    def buildSBOMLibrariesJob = build(
        job:       'build_sign_sbom_libraries',
        wait:      true,
        propagate: true
    )

    echo "build_sign_sbom_libraries completed: build #${buildSBOMLibrariesJob.getNumber()}"

    // ── Trigger sign_temurin_jsf downstream job ───────────────────────────────
    echo "Triggering sign_temurin_jsf..."
    def signSBOMJob = build(
        job: 'build-scripts/release/sign_temurin_jsf',
        parameters: [
            string(name: 'UPSTREAM_JOB_NUMBER',    value: env.BUILD_NUMBER                              ?: ''),
            string(name: 'UPSTREAM_JOB_NAME',      value: env.JOB_NAME                                 ?: ''),
            string(name: 'UPSTREAM_DIR',            value: '.'),
            string(name: 'SBOM_LIBRARY_JOB_NUMBER', value: "${buildSBOMLibrariesJob.getNumber()}"),
        ],
        wait:      true,
        propagate: true
    )

    echo "sign_temurin_jsf job completed: build #${signSBOMJob.getNumber()}"

    // ── Copy signed SBOM artifacts back ───────────────────────────────────────
    sh "mkdir -p '${env.TARGET_DIR}'"

    copyArtifacts(
        projectName:          'build-scripts/release/sign_temurin_jsf',
        selector:             specific("${signSBOMJob.getNumber()}"),
        filter:               '**/*sbom*.json',
        fingerprintArtifacts: true,
        target:               env.TARGET_DIR,
        flatten:              true
    )

    // ── Archive signed SBOMs ──────────────────────────────────────────────────
    archiveArtifacts artifacts: "${env.TARGET_DIR}/*sbom*.json"

    echo "✅ SBOM signing complete"
    return 0
}

return this
