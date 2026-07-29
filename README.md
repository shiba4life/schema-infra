# Schema Infrastructure

Standalone infrastructure for the FoldDB Schema Service (`schema.folddb.com`).

## Repository Venue

`schema-infra` is canonical in LastGit at `lastdb:///schema-infra`.
Change requests, CI, merges, and deploy gating happen through LastGit. GitHub
`EdgeVector/schema-infra` is a public read-only mirror for browse and clone only;
GitHub Actions are inert and disabled at the repository level.

Mirror details and launchd setup live in [`.lastgit/README.md`](.lastgit/README.md).

## Overview

This project contains everything needed to deploy the global schema registry for FoldDB:

- **Lambda Function**: Rust-based schema service with fastembed semantic search
- **S3 Bucket**: Schema blob persistence (one JSON object per schema)
- **API Gateway**: HTTP API with CORS and custom domain support
- **Frontend**: Web UI for browsing schemas

## Release planes

Every merge to `main` is classified by `scripts/deploy/classify-change.sh`
(design: design-schema-lambda-fast-deployment) and takes one of three paths
through `.lastgit/deploy-pipeline.sh`:

- **code-only** — the fold submodule pin changed, CDK inputs did not. The
  prebuilt, digest-verified artifact is published via the AWS CLI
  (`update-function-code` → CodeSha256 gate → `publish-version` → `live`
  alias / weighted prod canary). No CDK, no compilation in the release path.
- **infrastructure** — CDK, deploy machinery, or layer inputs changed. CDK
  deploys referencing the prebuilt artifact; Rust is never compiled inside
  the CDK path.
- **no-impact** — docs/tests/proofs/frontend only. The deploy is skipped
  with an explicit successful reason.

Artifacts are built once per input digest on the native x86_64 builder
(`scripts/remote-native-build.sh`) into a content-addressed store with a
secret-free manifest; pending main events coalesce to the newest eligible
tip before any expensive work. Evidence for the North Star terminal proof
is collected by `scripts/proof/schema-lambda-fast-deployment/collect.py`.

## Architecture

The schema service runs as a single Lambda function with two storage layers:

1. **S3 blob persistence** — each schema stored as `schemas/<name>.json` in an S3 bucket. Replaced the earlier Sled-on-/tmp approach, which was unreliable across cold starts. S3 gives durable, consistent storage with no /tmp size limits.
2. **fastembed Lambda Layer** — a pre-built layer bundles the fastembed model binary so the Lambda doesn't download it on every cold start. Cold start stays under 2s even with the embedding model loaded.

Lambda configuration:
- **Timeout**: 300 seconds (5 minutes) — required for fastembed model loading on first cold start
- **Memory**: 512 MB — required for embedding model inference

## Builtin Canonical Fields

On cold start the Lambda calls `seed_canonical_fields()` to pre-populate ~150 curated canonical fields (e.g., `user_email`, `photo_caption`, `gps_latitude`, `document_title`). Each field has a hardcoded description, data classification, and interest category. These are the shared vocabulary that enables schema deduplication and similarity across different FoldDB nodes.

Canonical fields are used by:
- Schema similarity detection (same semantic field → high similarity score)
- Schema expansion (safely add new fields without breaking existing data)
- Data browser field labeling

## Structure

```
schema-infra/
├── cdk/                    # CDK infrastructure (TypeScript)
│   ├── bin/               # CDK app entry point
│   ├── lib/               # Stack definitions
│   └── package.json       # CDK dependencies
├── fold/                  # Lambda handler source (submodule → EdgeVector/fold monorepo)
├── frontend/              # Schema registry web UI
├── build.sh              # Build Lambda zip + fastembed Layer
└── deploy.sh             # Deploy infrastructure
```

Lambda handler source lives in the [`EdgeVector/fold`](https://github.com/EdgeVector/fold) monorepo (which contains `fold_db`, `schema_service`, and `fold_db_node` in one cargo workspace), vendored here as a submodule at `fold/`. `build.sh` runs `cargo lambda build -p schema_service_server_lambda` from the monorepo workspace root and emits the deployable zip plus a fastembed Layer asset at `target/fastembed_layer/`.

## Quick Start

### Prerequisites

- Node.js 18+
- Rust (for Lambda build)
- AWS CLI configured
- CDK bootstrapped (`npx cdk bootstrap`)

### Build

```bash
./build.sh
```

### Deploy

```bash
# Deploy to dev
./deploy.sh dev

# Deploy to production (schema.folddb.com)
./deploy.sh prod
```

### Mutation-gate live proof

After deployment, prove the Schema Service proof-of-work path with the real
Rust client and live AWS telemetry:

```bash
scripts/deploy/prove-mutation-gate.sh
```

The command defaults to dev, verifies enforcement, a transparent
challenge/solve/registration, an idempotent repost, DynamoDB quota state, and
CloudWatch rejection/acceptance signals. Add `--quota-probe` for the bounded
dev-only run that stops on the first server-side quota rejection. Production
requires both `--environment prod` and `--allow-prod`; the quota probe is
refused in production. Output is a single secret-safe JSON report.

### Schema Lambda fast-deployment terminal proof

North Star terminal report for `north-star-schema-lambda-fast-deployment`.
Fail closed without redacted evidence; first line of
`proofs/schema-lambda-fast-deployment.md` is `PASS` only when all criteria
hold (ten-release timings, digests, dependency budget, path classification,
coalescing, smoke/canary/alarms, rollback). No raw secrets in evidence or
report.

```bash
# Operator (against a collected redacted evidence pack):
scripts/proof/schema-lambda-fast-deployment/prove.sh \
  --evidence-dir /path/to/redacted-evidence

# Harness self-check (CI; fixtures only — not live production PASS):
tests/proof/schema-lambda-fast-deployment/test-prove.sh
```

Details: [`scripts/proof/schema-lambda-fast-deployment/README.md`](scripts/proof/schema-lambda-fast-deployment/README.md).

### Custom Domain

To enable the `schema.folddb.com` custom domain:

1. Create an ACM certificate for `schema.folddb.com` in us-east-1
2. Set the environment variable:
   ```bash
   export SCHEMA_DOMAIN_CERT_ARN="arn:aws:acm:us-east-1:..."
   ```
3. Deploy with `./deploy.sh prod`
4. Add a CNAME record pointing `schema.folddb.com` to the API Gateway domain

## Frontend

The frontend is a static site in `frontend/`. To serve locally:

```bash
cd frontend
python3 -m http.server 8080
```

Deploy to Vercel or another static hosting service.

## API Endpoints

The Lambda serves the full `/v1/*` surface — 19 endpoints covering
schemas, views, transforms, and system. See the machine-readable spec
at [`fold/schema_service/openapi.yaml`](https://github.com/EdgeVector/fold/blob/main/schema_service/openapi.yaml).

A few representative routes:

| Method | Path                         | Description                              |
| ------ | ---------------------------- | ---------------------------------------- |
| GET    | `/v1/health`                 | Health check                             |
| GET    | `/v1/schemas`                | List schema names                        |
| GET    | `/v1/schemas/available`      | Get all schemas with definitions         |
| GET    | `/v1/schema/{name}`          | Get a specific schema                    |
| POST   | `/v1/schemas`                | Register / propose a schema              |
| POST   | `/v1/schemas/batch-check-reuse` | Batch reuse-check for proposed schemas |
| GET    | `/v1/snapshot/shared-only`   | Export shared-only snapshot for resolver packs |
| GET    | `/v1/views`                  | List view names                          |
| GET    | `/v1/transforms`             | List transform records                   |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SCHEMAS_BUCKET` | S3 bucket name for schema blob storage |
| `FASTEMBED_CACHE_DIR` | Path to pre-extracted fastembed model (provided by Lambda Layer) |
| `OBS_SENTRY_DSN` | Optional Sentry project DSN exported before CDK synth/deploy; empty disables the Sentry sink |
| `OBS_SENTRY_RELEASE` | Sentry release tag; `deploy.sh` defaults this to `schema-infra@<git-sha>` |
| `OBS_SENTRY_ENVIRONMENT` | Sentry environment tag; `deploy.sh` defaults this to the deploy target (`dev` or `prod`) |

## Storage Backend

Schemas are stored in S3 as individual JSON blobs:

```
s3://<SCHEMAS_BUCKET>/schemas/<schema_name>.json
```

The `ExternalSchemaPersistence` trait allows plugging in alternative backends. The Lambda uses `S3SchemaPersistence`; the dev binary in [`fold/schema_service/crates/server_http/`](https://github.com/EdgeVector/fold/tree/main/schema_service/crates/server_http) uses `SledSchemaPersistence` (default port 9102, for local development).

## fastembed Lambda Layer

The fastembed model is bundled as a Lambda Layer (`fastembed-model-layer`) and mounted at `/opt/fastembed/`. The Lambda reads `FASTEMBED_CACHE_DIR=/opt/fastembed` so it never downloads the model at runtime. The layer is published once and referenced by ARN in the CDK stack.

## License

MIT / Apache 2.0
