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
 * Temurin Vendor Implementation: 10-digital-artifact-sign
 *
 * Applies detached GPG signatures (.sig) to all build artifacts by triggering
 * the downstream sign_temurin_gpg job and copying the resulting .sig files
 * back into TARGET_DIR for archiving.
 *
 * Equivalent to the legacy gpgSign() function in openjdk_build_pipeline.groovy.
 *
 * Gate condition (enforced by stageCondition in 10-digital-artifact-sign.params.json):
 *   - SIGN_ARTIFACTS must be true
 *
 * Environment Variables (set by StageScriptRunner.run() via withEnv):
 *   WORKSPACE            - Stage workspace directory
 *   CONFIG_FILE          - Path to pipeline-config.json
 *   INPUT_ARTIFACTS_DIR  - Directory containing artifacts to sign
 *   BUILD_OUTPUT_DIR     - Relative subfolder under INPUT_ARTIFACTS_DIR containing build outputs
 *   TARGET_DIR           - Directory for .sig output files
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
    if (signArtifacts.toLowerCase() != 'true') {
        echo "ℹ️  10-digital-artifact-sign: SIGN_ARTIFACTS='${signArtifacts}' is not true — skipping"
        return 0
    }

    echo "=== Temurin Digital Artifact Sign Stage ==="
    echo "  UPSTREAM_JOB_NAME  : ${env.JOB_NAME}"
    echo "  UPSTREAM_JOB_NUMBER: ${env.BUILD_NUMBER}"
    echo "  TARGET_DIR         : ${env.TARGET_DIR}"

    // ── Trigger sign_temurin_gpg downstream job ───────────────────────────────
    String buildOutputDir = env.BUILD_OUTPUT_DIR
    if (!buildOutputDir) {
        error('BUILD_OUTPUT_DIR is not set — ensure stage-constants.properties is present and loaded')
    }
    def signJob = build(
        job: 'build-scripts/release/sign_temurin_gpg',
        parameters: [
            string(name: 'UPSTREAM_JOB_NUMBER', value: env.BUILD_NUMBER ?: ''),
            string(name: 'UPSTREAM_JOB_NAME',   value: env.JOB_NAME     ?: ''),
            string(name: 'UPSTREAM_DIR',         value: buildOutputDir),
        ],
        wait:      true,
        propagate: true
    )

    echo "sign_temurin_gpg job completed: build #${signJob.getNumber()}"

    // ── Copy .sig artifacts back from the sign job ────────────────────────────
    String targetBuildOutput = "${env.TARGET_DIR}/${buildOutputDir}"
    sh "mkdir -p '${targetBuildOutput}'"

    copyArtifacts(
        projectName:          'build-scripts/release/sign_temurin_gpg',
        selector:             specific("${signJob.getNumber()}"),
        filter:               '**/*.sig',
        fingerprintArtifacts: true,
        target:               targetBuildOutput,
        flatten:              true
    )

    echo "✅ Digital artifact signing complete"
    return 0
}

return this
