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
 * Temurin Vendor Implementation: 16-publish
 *
 * Triggers the downstream Temurin publish job
 * (build-scripts/job/release/job/refactor_openjdk_release_tool) with the
 * parameters derived from the current build context.
 *
 * Gate conditions (enforced in 16-publish.params.json stageCondition, but also
 * checked here for defence-in-depth):
 *   - RELEASE_TYPE must be "RELEASE" or "WEEKLY"
 *   - SCM_REF must be non-empty
 *
 * Called by StageScriptRunner with the pipeline config Map as the sole argument.
 * Returns 0 on success, 1 on failure.
 */

/**
 * Entry point called by StageScriptRunner._dispatch():
 *   def script = load(found.path)
 *   exitCode = script(config) ?: EXIT_SUCCESS
 */
int call(Map config) {

    // ── Gate check ────────────────────────────────────────────────────────────
    String releaseType = env.RELEASE_TYPE ?: ''
    String scmRef      = env.SCM_REF      ?: ''

    if (!(releaseType in ['RELEASE', 'WEEKLY'])) {
        echo "ℹ️  16-publish: RELEASE_TYPE='${releaseType}' is not RELEASE or WEEKLY — skipping"
        return 0
    }
    if (!scmRef) {
        echo "ℹ️  16-publish: SCM_REF is not set — skipping"
        return 0
    }

    // ── Derive publish parameters ─────────────────────────────────────────────

    // RELEASE: true only for RELEASE builds
    boolean release = (releaseType == 'RELEASE')

    // DRY_RUN: always true for RELEASE (safety gate), always false for WEEKLY
    boolean dryRun = (releaseType == 'RELEASE')

    // TAG: use OVERRIDE_PUBLISH_NAME when set by the trigger pipeline (it already
    // has the correct form, e.g. "jdk-21.0.5+11-ea").  Fall back to deriving from
    // SCM_REF for manual builds where OVERRIDE_PUBLISH_NAME is not supplied.
    String overridePublishName = env.OVERRIDE_PUBLISH_NAME?.trim() ?: ''
    String tag
    if (overridePublishName) {
        tag = overridePublishName
        echo "  Using OVERRIDE_PUBLISH_NAME: ${tag}"
    } else {
        tag = scmRef.replace('_adopt', '')
        if (releaseType == 'WEEKLY') {
            tag = "${tag}-ea"
        }
        echo "  Derived TAG from SCM_REF: ${tag}"
    }

    // TIMESTAMP: current UTC date in the format expected by the publish job
    String timestamp = new Date().format('yyyy-MM-dd-HH-mm', TimeZone.getTimeZone('UTC'))

    // UPSTREAM job identity — standard Jenkins env vars
    String upstreamJobName   = env.JOB_NAME    ?: ''
    String upstreamJobNumber = env.BUILD_NUMBER ?: ''

    // VERSION: the JDK major version string (e.g. "21")
    String version = env.JDK_VERSION ?: ''

    // TARGET_OS: resolved from the pipeline config by ConfigHelper
    String targetOs = env.CONFIG_TARGET_OS ?: ''

    // ARTIFACTS_TO_COPY: comma-separated list of matching artifact basenames
    String artifactsToCopy = resolveArtifactsToCopy(targetOs)

    // ── Log resolved parameters ───────────────────────────────────────────────
    echo "=== Temurin Publish Stage ==="
    echo "  RELEASE_TYPE       : ${releaseType}"
    echo "  RELEASE            : ${release}"
    echo "  DRY_RUN            : ${dryRun}"
    echo "  TAG                : ${tag}"
    echo "  TIMESTAMP          : ${timestamp}"
    echo "  UPSTREAM_JOB_NAME  : ${upstreamJobName}"
    echo "  UPSTREAM_JOB_NUMBER: ${upstreamJobNumber}"
    echo "  VERSION            : ${version}"
    echo "  TARGET_OS          : ${targetOs}"
    echo "  ARTIFACTS_TO_COPY  : ${artifactsToCopy}"

    // ── Trigger downstream publish job ────────────────────────────────────────
    def result = build(
        job: 'build-scripts/job/release/job/refactor_openjdk_release_tool',
        parameters: [
            booleanParam(name: 'RELEASE',              value: release),
            booleanParam(name: 'DRY_RUN',              value: dryRun),
            string(name:      'TAG',                   value: tag),
            string(name:      'TIMESTAMP',             value: timestamp),
            string(name:      'UPSTREAM_JOB_NAME',     value: upstreamJobName),
            string(name:      'UPSTREAM_JOB_NUMBER',   value: upstreamJobNumber),
            string(name:      'VERSION',               value: version),
            string(name:      'ARTIFACTS_TO_COPY',     value: artifactsToCopy),
        ],
        wait:      true,
        propagate: false
    )

    echo "Publish job result: ${result.result}"

    if (result.result != 'SUCCESS') {
        echo "❌ Publish job failed with result: ${result.result}"
        return 1
    }

    echo "✅ Publish job completed successfully"
    return 0
}

/**
 * Build the ARTIFACTS_TO_COPY value by listing artifact files in
 * INPUT_ARTIFACTS_DIR that match the OS-specific extensions.
 *
 * @param targetOs  The CONFIG_TARGET_OS value: "linux", "windows", or "mac"
 * @return Comma-separated list of matching basenames beginning with "OpenJDK"
 */
String resolveArtifactsToCopy(String targetOs) {
    List extensions
    switch (targetOs) {
        case 'windows':
            extensions = ['.zip', '.msi', '.sha256.txt', '.json', '.sig']
            break
        case 'mac':
            extensions = ['.tar.gz', '.pkg', '.sha256.txt', '.json', '.sig']
            break
        default: // linux and everything else
            extensions = ['.tar.gz', '.sha256.txt', '.json', '.sig']
            break
    }

    String inputDir = env.INPUT_ARTIFACTS_DIR ?: env.WORKSPACE
    List artifacts = []
    extensions.each { String ext ->
        def found = sh(
            script: "find '${inputDir}' -maxdepth 1 -name 'OpenJDK*${ext}' -printf '%f\\n' 2>/dev/null || true",
            returnStdout: true
        ).trim()
        if (found) {
            found.split('\n').each { String name -> if (name) { artifacts << name } }
        }
    }

    return artifacts.unique().join(',')
}

return this
