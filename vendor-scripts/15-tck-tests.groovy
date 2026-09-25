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
 * Temurin Vendor Implementation: 15-tck-tests
 *
 * Triggers the downstream AQA_Test_Pipeline_JCK job with the archived JDK URL.
 * The job is fired asynchronously (wait:false / waitForStart:true) and a link
 * is appended to the build description. Trigger failures set the build result
 * to FAILURE without throwing.
 *
 * Equivalent to the legacy remoteTriggerJckTests(jdkFileName) function in
 * openjdk_build_pipeline.groovy.
 *
 * Gate conditions (enforced by stageCondition in 15-tck-tests.params.json):
 *   - ENABLE_TCK   must be true
 *   - RELEASE_TYPE must be RELEASE or WEEKLY
 *
 * Environment Variables (set by StageScriptRunner.run() via withEnv, and
 * ConfigHelper.generatePipelineConfig()):
 *   INPUT_ARTIFACTS_DIR  - Directory containing archived JDK artifacts
 *   BUILD_URL            - URL of the current Jenkins build
 *   RELEASE_TYPE         - NIGHTLY | WEEKLY | RELEASE
 *   SCM_REF              - Source tag/ref used for this build
 *   CONFIG_TARGET_OS     - Target OS (linux, windows, mac, …)
 *   CONFIG_ARCHITECTURE  - Architecture (x64, aarch64, …)
 *   CONFIG_JAVA_TO_BUILD - Java version string (jdk21, jdk8u, …)
 */

/**
 * Entry point called by StageScriptRunner._dispatch():
 *   def script = load(found.path)
 *   exitCode = script(config) ?: EXIT_SUCCESS
 */
int call(Map config) {

    // ── Gate check ────────────────────────────────────────────────────────────
    String runTests    = env.RUN_TESTS     ?: ''
    String enableTck   = env.ENABLE_TCK    ?: ''
    String releaseType = (env.RELEASE_TYPE ?: '').toUpperCase()

    if (runTests.toLowerCase() != 'true') {
        echo "ℹ️  15-tck-tests: RUN_TESTS='${runTests}' is not true — skipping"
        return 0
    }
    if (enableTck.toLowerCase() != 'true') {
        echo "ℹ️  15-tck-tests: ENABLE_TCK='${enableTck}' is not true — skipping"
        return 0
    }
    if (!(releaseType in ['RELEASE', 'WEEKLY'])) {
        echo "ℹ️  15-tck-tests: RELEASE_TYPE='${releaseType}' is not RELEASE or WEEKLY — skipping"
        return 0
    }

    // ── Resolve build context ─────────────────────────────────────────────────
    String scmRef       = env.SCM_REF             ?: ''
    String targetOs     = env.CONFIG_TARGET_OS    ?: ''
    String architecture = env.CONFIG_ARCHITECTURE ?: ''
    String javaToBuild  = (env.CONFIG_JAVA_TO_BUILD ?: '').trim().toUpperCase()
    String buildUrl     = env.BUILD_URL           ?: ''
    String inputDir     = env.INPUT_ARTIFACTS_DIR ?: env.WORKSPACE

    // ── Derive JDK version number (e.g. "JDK21" → "21") ──────────────────────
    String jdkVersion = javaToBuild.replaceAll(/[^0-9]/, '')

    // ── Map architecture to AQA naming convention ─────────────────────────────
    String arch = (architecture == 'x64') ? 'x86-64' : architecture
    String archOsList = "${arch}_${targetOs}"

    // ── Determine build_type from RELEASE_TYPE ────────────────────────────────
    String buildType = (releaseType == 'RELEASE') ? 'release' : 'weekly'

    // ── Find the JDK archive in INPUT_ARTIFACTS_DIR ───────────────────────────
    String extension = (targetOs == 'windows') ? 'zip' : 'tar.gz'
    String jdkFileName = sh(
        script: "find '${inputDir}' -maxdepth 1 -name 'OpenJDK*-jdk_*.${extension}' -printf '%f\\n' 2>/dev/null | head -1 || true",
        returnStdout: true
    ).trim()

    if (!jdkFileName) {
        echo "❌ 15-tck-tests: no JDK archive (OpenJDK*-jdk_*.${extension}) found in ${inputDir}"
        currentBuild.result = 'FAILURE'
        return 1
    }

    String sdkUrl = "${buildUrl}artifact/workspace/target/${jdkFileName}"

    // ── Log resolved parameters ───────────────────────────────────────────────
    echo "=== TCK Test Stage ==="
    echo "  JDK_VERSIONS       : ${jdkVersion}"
    echo "  BUILD_TYPE         : ${buildType}"
    echo "  PLATFORMS          : ${archOsList}"
    echo "  CUSTOMIZED_SDK_URL : ${sdkUrl}"

    // ── Trigger AQA_Test_Pipeline_JCK (fire-and-forget) ──────────────────────
    try {
        String displayName = "jdk${jdkVersion} : ${scmRef} : ${buildType} : ${archOsList}"
        echo "Triggering AQA_Test_Pipeline_JCK : ${displayName}"

        def jckJob = build(
            job: 'AQA_Test_Pipeline_JCK',
            parameters: [
                string(name: 'SDK_RESOURCE',          value: 'customized'),
                string(name: 'CUSTOMIZED_SDK_URL',    value: sdkUrl),
                string(name: 'JDK_VERSIONS',          value: jdkVersion),
                string(name: 'PLATFORMS',             value: archOsList),
                string(name: 'PIPELINE_DISPLAY_NAME', value: displayName),
                string(name: 'BUILD_TYPE',            value: buildType),
            ],
            wait:         false,
            waitForStart: true
        )

        String link
        if (jckJob?.absoluteUrl && jckJob?.number) {
            link = "<a href='${jckJob.absoluteUrl}'>AQA_Test_Pipeline_JCK #${jckJob.number}</a>"
        } else {
            link = "<a href='${env.JENKINS_URL}job/AQA_Test_Pipeline_JCK/'>AQA_Test_Pipeline_JCK (no build number available)</a>"
        }
        currentBuild.description = (currentBuild.description ?: '') + "<br>${link}"

    } catch (Exception e) {
        echo "❌ Failed to trigger TCK tests: ${e.message}"
        currentBuild.result = 'FAILURE'
        return 1
    }

    echo "✅ TCK test pipeline triggered"
    return 0
}

return this
