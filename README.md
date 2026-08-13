
Vendor configuration repository for Eclipse Temurin OpenJDK builds. Consumed at runtime by the [ci-adoptium-pipelines](https://github.com/adoptium/ci-adoptium-pipelines) build tool.

This repository implements the code/config separation pattern: all pipeline *code* lives in `ci-adoptium-pipelines`; all Temurin-specific *configuration* and *stage overrides* live here. The pipeline clones this repository at the start of every build (Initialize stage) via the `CONFIG_REPO_URL` / `CONFIG_REPO_BRANCH` parameters.

---

## Repository Structure

```
ci-temurin-config/
├── adoptium_pipeline_config.json        # Top-level pipeline defaults and repository URLs
├── jenkins_job_config.json              # Jenkins job DSL settings (log rotation, default parameters)
├── configurations/                      # Per-JDK-version platform build matrices
│   ├── jdk8_pipeline_config.json
│   ├── jdk11_pipeline_config.json
│   ├── jdk17_pipeline_config.json
│   ├── jdk21_pipeline_config.json
│   ├── jdk25_pipeline_config.json
│   ├── jdk26_pipeline_config.json
│   ├── jdk27_pipeline_config.json
│   ├── jdk28_pipeline_config.json
│   └── ...  (jdk15–jdk24 present but disabled)
└── vendor-scripts/                      # Temurin-specific stage script overrides
    ├── 12-validate-sbom.sh
    ├── 13-smoke-tests.sh
    └── 20-reproducible-compare.sh
```

---

## Configuration Files

### `adoptium_pipeline_config.json`

Top-level file read by the Launch pipeline (`Jenkinsfile.launch`) and the local runner. Defines:

| Field | Purpose |
|---|---|
| `activeJdkVersions` | Array of `{ "version": "jdkNN", "enabled": true/false }` entries — controls which JDK versions the Launch pipeline fans out to |
| `defaultBuildArgs` | Build args passed to every platform unless overridden (e.g. `"--create-jre-image --create-sbom"`) |
| `defaultConfigureArgs` | OpenJDK `configure` args passed to every platform unless overridden |
| `defaultVariant` | Variant string (`"temurin"`) used when variant-keyed config fields are resolved |
| `defaultScmReference` | Default SCM ref/tag — empty means use the version's default branch |
| `configFilePrefix` / `configFileSuffix` | Template for locating per-version config files (e.g. `"configurations/"` + `"_pipeline_config.json"`) |
| `repository.url` | `ci-adoptium-pipelines` repository URL |
| `repository.branch` | Pipeline code branch |
| `repository.buildRepoUrl` / `buildBranch` | `temurin-build` repository URL and branch |
| `repository.aqaRepoUrl` / `aqaBranch` | `aqa-tests` repository URL and branch |

### `jenkins_job_config.json`

Read by the Jenkins Job DSL seed job to configure generated pipeline jobs. Fields:

| Field | Purpose |
|---|---|
| `jenkinsfilePath` | Path to the Jenkinsfile within `ci-adoptium-pipelines` (e.g. `"ci/jenkins/Jenkinsfile.declarative"`) |
| `pipelineTimeoutHours` | Global build timeout in hours |
| `jobConfiguration.defaultParameters` | Default values for pipeline parameters (`VARIANT`, `CLEAN_WORKSPACE_AFTER_STAGE`, `RUN_TESTS`, `ENABLE_INSTALLERS`, `SIGN_ARTIFACTS`, `PUBLISH_ARTIFACTS`, `RUN_REPRODUCIBLE_COMPARE`) |
| `jobConfiguration.logRotation` | Artifact and build retention policy (`daysToKeep`, `numToKeep`, `artifactDaysToKeep`, `artifactNumToKeep`) |

### `configurations/jdkNN_pipeline_config.json`

One file per JDK version. Defines the platform build matrix for that version. Top-level fields:

| Field | Purpose |
|---|---|
| `version` | Version identifier (e.g. `"jdk21"`) |
| `openjdkVersion` | OpenJDK source version string (e.g. `"jdk21u"`) — may differ from `version` for update releases |
| `enabled` | Whether this version is active |
| `buildConfigurations` | Map of platform-key → platform config (see below) |
| `targetConfigurations` | Ordered list of platform keys to build — determines which platforms are triggered |

**Platform configuration keys** (inside `buildConfigurations.<platformKey>`):

| Field | Type | Purpose |
|---|---|---|
| `os` | string | Target OS: `linux`, `mac`, `windows`, `aix`, `alpine-linux`, `solaris` |
| `arch` | string | Target arch: `x64`, `aarch64`, `ppc64`, `ppc64le`, `s390x`, `arm`, `riscv64`, `x86-32`, `sparcv9` |
| `additionalNodeLabels` | string or variant-map | Jenkins node label expression (or per-variant map) |
| `dockerImage` | string or variant-map | Docker image name for containerised builds |
| `dockerRegistry` | string | Docker registry URL (e.g. `https://adoptium.azurecr.io`) |
| `dockerCredential` | string | Jenkins credentials ID for the registry |
| `dockerArgs` | string | Extra arguments passed to `docker run` (e.g. `"--platform linux/riscv64"`) |
| `dockerFile` | string or variant-map | Path to a Dockerfile override |
| `crossCompile` | string | Cross-compile host arch or emulator (e.g. `"x64"`, `"qemustatic"`) |
| `configureArgs` | string or variant-map | Arguments appended to OpenJDK `configure` |
| `buildArgs` | string or variant-map | Arguments passed to `make-adopt-build-farm.sh` / `02-build.sh` |
| `test` | string or object | `"default"` for the standard suite; an object with release-type keys (`nightly`, `weekly`, `release`) for selective suites |
| `additionalTestLabels` | string or variant-map | AQA test node label expressions |
| `additionalTestParams` | variant-map of objects | Extra AQA parameters per variant (e.g. `{ "temurin": { "CLOUD_PROVIDER": "azure" } }`) |
| `cleanWorkspaceAfterBuild` | bool | Clean the workspace after Build stage (useful for space-constrained nodes) |

**Variant-keyed fields**: many fields accept either a plain string (applied to all variants) or an object keyed by variant name (e.g. `"temurin"`, `"openj9"`, `"hotspot"`) to allow per-variant overrides:

```json
"configureArgs": {
    "temurin": "--enable-dtrace",
    "openj9": "--enable-dtrace --enable-jitserver"
}
```

**Example — a modern LTS platform entry:**

```json
"aarch64Linux": {
    "os": "linux",
    "arch": "aarch64",
    "dockerImage": "adoptopenjdk/centos7_build_image",
    "configureArgs": {
        "temurin": "--enable-dtrace --with-jobs=4"
    },
    "buildArgs": {
        "temurin": "--create-jre-image --create-sbom --enable-sbom-strace --use-adoptium-devkit gcc-11.3.0-Centos7.6.1810-b04"
    },
    "test": {
        "weekly": ["sanity.openjdk", "extended.functional", "extended.openjdk"]
    }
}
```

### Active JDK versions (current)

| Version | File | Enabled |
|---|---|---|
| JDK 8 | `jdk8_pipeline_config.json` | Yes |
| JDK 11 | `jdk11_pipeline_config.json` | Yes |
| JDK 17 | `jdk17_pipeline_config.json` | Yes |
| JDK 21 | `jdk21_pipeline_config.json` | Yes |
| JDK 25 | `jdk25_pipeline_config.json` | Yes |
| JDK 26 | `jdk26_pipeline_config.json` | Yes |
| JDK 27 | `jdk27_pipeline_config.json` | Yes |
| JDK 28 | `jdk28_pipeline_config.json` | Yes |
| JDK 15–16, 18–24 | present | No (`"enabled": false`) |

---

## Vendor Scripts

The `vendor-scripts/` directory contains Temurin-specific overrides for pipeline stage scripts. At runtime the stage resolver checks this directory first; if a matching script is found it takes priority over the default stub in `ci-adoptium-pipelines/scripts/stages/`.

### `13-smoke-tests.sh`

Runs the AQA `extended.functional` / `functional/buildAndPackage` test suite against the freshly built JDK. Clones `aqa-tests`, runs `get.sh` to pull in `temurin-build` functional tests, then invokes `make compile && make _extended.functional` via the TKG test framework.

Sources `${PIPELINE_ROOT}/scripts/lib/logging-utils.sh` and `config-utils.sh` from `ci-adoptium-pipelines`.

**Required env:** `WORKSPACE`, `CONFIG_FILE`, `INPUT_ARTIFACTS_DIR`, `TARGET_DIR`, `BUILD_NUMBER`
**Reads from config:** `JAVA_TO_BUILD`, `TARGET_OS`, `ARCHITECTURE`, `repoDefaults.aqaRef`, `repoDefaults.aqaRepoUrl`, `repoDefaults.buildRef`, `repoDefaults.buildRepoUrl`
**Outputs:** TKG result tree in `TARGET_DIR/`, `TARGET_DIR/smoke-test-summary.json`

### `12-validate-sbom.sh`

Validates SBOM JSON files produced by the Build stage. Clones `temurin-build` and invokes `tooling/validateSBOM.sh` against every `*sbom*.json` file found in `INPUT_ARTIFACTS_DIR`. Only meaningful when `--create-sbom` is in `buildArgs`.

**Required env:** `WORKSPACE`, `CONFIG_FILE`, `INPUT_ARTIFACTS_DIR`, `TARGET_DIR`
**Optional env:** `TEMURIN_BUILD_REPO`, `TEMURIN_BUILD_BRANCH`, `JAVA_VERSION`, `SCM_REF`

### `20-reproducible-compare.sh`

Downloads the published Adoptium production binary for the same version from `api.adoptium.net`, unpacks both the production and locally built JDKs, then delegates to `temurin-build/tooling/reproducible/repro_compare.sh` for byte-level comparison.

Sources `${PIPELINE_ROOT}/scripts/lib/logging-utils.sh` and `config-utils.sh` from `ci-adoptium-pipelines`.

**Required env:** `WORKSPACE`, `CONFIG_FILE`, `INPUT_ARTIFACTS_DIR`, `TARGET_DIR`, `SCM_REF`, `RELEASE`, `PIPELINE_ROOT`
**Optional env:** `BUILD_REPO_URL`, `BUILD_REF`
**Outputs:** `TARGET_DIR/comparison-report.txt`, `TARGET_DIR/reprotest.diff`, `TARGET_DIR/ReproduciblePercent`

---

## Local Usage

```bash
# Clone both repos
git clone https://github.com/adoptium/ci-adoptium-pipelines.git
git clone https://github.com/adoptium/ci-temurin-config.git

# Run a full pipeline locally (Initialize + Build + Smoke Tests)
cd ci-adoptium-pipelines
python3 ci/local/run-pipeline.py \
    --workspace ~/openjdk-build \
    --jdk-version jdk21 \
    --target-os mac \
    --arch aarch64 \
    --release-type NIGHTLY \
    --config-repo-url ../ci-temurin-config \
    --config-repo-branch main

# Validate JSON syntax before committing
jq empty ../ci-temurin-config/configurations/jdk21_pipeline_config.json
```

---

## Related Documentation

- [ci-adoptium-pipelines](https://github.com/adoptium/ci-adoptium-pipelines) — pipeline repository
- [docs/CODE_CONFIG_SEPARATION.md](https://github.com/adoptium/ci-adoptium-pipelines/blob/main/docs/CODE_CONFIG_SEPARATION.md) — config repo schema reference
- [docs/PIPELINE_RUNNER_GUIDE.md](https://github.com/adoptium/ci-adoptium-pipelines/blob/main/docs/PIPELINE_RUNNER_GUIDE.md) — local runner CLI reference
- [docs/CI_AGNOSTIC_ARCHITECTURE.md](https://github.com/adoptium/ci-adoptium-pipelines/blob/main/docs/CI_AGNOSTIC_ARCHITECTURE.md) — pipeline architecture overview
