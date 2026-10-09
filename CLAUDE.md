# freshehr-open-health-stack — working notes for Claude

## What this repo is

An openEHR → FHIR health-data stack in three IaC layers, all driven from the
root `Makefile` (run `make help`):

1. **docker-compose** (`docker/`) — the whole 8-service stack locally. This is
   the **verification environment**: every upgrade is proven here.
2. **Helm chart** (`charts/health-stack/`) — the same topology for Kubernetes.
   Verified via `make helm-lint` / `make helm-render` only (no live cluster
   needed for routine changes).
3. **Terraform** (`terraform/`) — Hetzner k3s provisioning that installs the
   chart.

Services: HAPI FHIR (+ openFHIR interceptor), EHRbase, openFHIR engine, hades
(FHIR terminology server, `/terminology` at the edge), Keycloak, oauth2-proxy,
one shared Postgres, nginx.

## Gitignored prerequisites (needed before anything builds/runs)

- `docker/openfhir/license/openfhir-license.json` — vendor license
  (request at https://open-fhir.com#access).

(The openFHIR HAPI interceptor JAR is no longer a prerequisite — it is fetched
at build time from the pinned GitHub release asset; see the interceptor pin in
the table below.)

## Image pins — every location

Compose and chart MUST declare the same tag for shared components;
`make versions` fails on any mismatch.

| Component        | Compose                            | Chart                                | Notes |
|------------------|------------------------------------|--------------------------------------|-------|
| ehrbase          | `docker/docker-compose.yml:76`     | `charts/health-stack/values.yaml:207`| version-coupled env, see below |
| keycloak         | `docker/docker-compose.yml:130`    | `charts/health-stack/values.yaml:328`| |
| oauth2-proxy     | `docker/docker-compose.yml:208`    | `charts/health-stack/values.yaml:358`| |
| postgres         | `docker/docker-compose.yml:239`    | `charts/health-stack/values.yaml:372`| must stay the ehrbase vendor image |
| openfhir         | `docker/docker-compose.yml:276`    | `charts/health-stack/values.yaml:257`| must stay `openfhir-enterprise` |
| nginx            | `docker/docker-compose.yml:342`    | — (k8s uses ingress-nginx)           | |
| hapi (upstream)  | `docker/hapi/Dockerfile:25` (`ARG HAPI_BASE`) | —                         | the real HAPI pin; compose builds locally |
| hapi (interceptor) | `docker/hapi/Dockerfile:22` (`ARG INTERCEPTOR_VERSION`) | — | openFHIR interceptor; fetched at build from the GitHub release asset (`releases ≥ 2.0.0` ship the jar; older tags have none → build fails). No sha256 asset published upstream. |
| hapi (pushed)    | —                                  | `charts/health-stack/values.yaml:92` + `values-hetzner.yaml:49` (prod override — the tag terraform actually deploys) | team image on `ghcr.io/freshehrteam` (CI `build-images.yml`); chart pins an explicit tag matching `Chart.yaml version` — produced by CI's `type=semver` on the `v<version>` git tag (or `make images-push IMAGE_TAG=<version>`). **`values-hetzner.yaml` overrides win for prod — bump the tag THERE too.** Publish the tag before `terraform apply`. |
| eps-mappings     | —                                  | `charts/health-stack/values.yaml:103` + `values-hetzner.yaml:52` | team image on `ghcr.io/freshehrteam`; same explicit-tag rule as hapi (pushed) |
| hades (jar)      | `docker/hades/Dockerfile:21` (`ARG HADES_VERSION` + `HADES_SHA256`, bumped in lockstep) | — | the real upstream pin; fetch the release's `.jar.sha256` asset |
| hades (pushed)   | `docker/docker-compose.yml:320`    | `charts/health-stack/values.yaml:110` + `values-hetzner.yaml:55` | team image `ghcr.io/freshehrteam/hades`; same explicit-tag rule as hapi (pushed) |

## Code style

- Keep code comments minimal: none unless the code is non-obvious, and one line at most.

## Hard constraints (learned the hard way — do not "simplify" these away)

- **openFHIR must stay `openfhir/openfhir-enterprise`**, never the community
  `openfhir` image: only enterprise ships the Postgres repository
  (`openfhir.db.type=postgres`); community is Mongo-only and dies with
  "No qualifying bean … FhirConnectModelRepository".
- **`SPRING_CONFIG_ADDITIONAL_LOCATION: file:/app/application.yaml`** on the
  openfhir service is load-bearing: the Docker Hub image sets no WORKDIR, so
  the mounted config is silently ignored without it (symptom is a bean error,
  not a config error). See the comment at `docker/docker-compose.yml:277`.
- **Postgres must stay `ehrbase/ehrbase-v2-postgres`** — EHRbase needs the
  extensions/roles that vendor image pre-provisions.
- **EHRbase `MANAGEMENT_ENDPOINT_HEALTH_*` is version-coupled to the image tag
  and must match in BOTH layers**: ≥2.35 needs `…HEALTH_ACCESS: READ_ONLY`,
  ≤2.28 needs `…HEALTH_ENABLED: "true"`; Spring treats the pair as mutually
  exclusive, so the wrong one for the image generation crashes EHRbase at
  startup. Locations: `docker/docker-compose.yml` ehrbase env +
  `charts/health-stack/values.yaml` ehrbase.env.
- **Bump `charts/health-stack/Chart.yaml` `version:` on EVERY chart change** —
  terraform's helm provider only re-renders when that version changes;
  without a bump `terraform apply` silently reports "No changes".
- **Keycloak `--import-realm` never updates an existing realm.** The realm
  JSON is duplicated in `docker/keycloak/realm-freshehr.json` AND
  `charts/health-stack/config/realm-freshehr.json.tpl` — synced BY HAND; edit
  both. To pick up realm changes: compose = `make destroy` (volume wipe);
  live cluster = the runbook in `charts/health-stack/README.md`
  ("Runbook: updating the realm on a LIVE cluster").
- **The interceptor JAR is compiled against a specific HAPI FHIR library
  version** (its deps are `provided`-scope, so they bind to whatever the HAPI
  base image ships at runtime). Keep `ARG INTERCEPTOR_VERSION` compatible with
  `ARG HAPI_BASE`: a major HAPI bump means pinning a newer interceptor release
  built against that generation — NOT rebuilding from source. The JAR is fetched
  from the release asset (`curl -f`), so a version with no published `.jar`
  asset (anything below `2.0.0`) fails the build by design.
- **`make destroy` wipes hades' terminology data too** (`hades-data` volume).
  fhir.db self-restores on the next boot (entrypoint bootstrap — takes minutes;
  use `WAIT_TIMEOUT=420 make wait`), but any imported SNOMED/LOINC db is lost
  and must be re-imported (`make hades-snomed SNOMED_ZIP=...`).

## Known silent failure

Stale/colliding openFHIR mappers (reused Postgres volume, or IPS + EPS sets
loaded together) keep `$tofhir` answering **200** — but with a bare
`{Bundle, Composition}` and zero clinical resources. `make smoke` stays green
through this; **only `make verify` catches it** (`$tofhir` entry-count check).
Fix: `make destroy`, clean start.

## Canonical clean start

```bash
make destroy && make build && make up && make wait && make template && make bootstrap && make verify
```

## Test commands

| Command | What it proves |
|---|---|
| `make wait` | every service answers (incl. HAPI, which has no compose healthcheck, and hades via `/terminology`) |
| `make smoke` | auth matrix: 401 bare / 200 Bearer (incl. `/terminology/fhir/metadata`), health + discovery public |
| `make verify` | data plane: templates, tenant-visible mappings, EPS ingest → 201, AQL row, tofhir with real clinical resources, hades `$lookup` content, read-back |
| `make versions` | declared pins (compose/Dockerfile/chart) vs running; fails on compose↔chart drift |
| `make helm-lint` / `make helm-render ENV=dev` | chart sanity (`ENV=hetzner` render needs out-of-band secrets) |
| UI: `cd ../freshehr-nictiz-ui/app && npm run stack:verify` | unit tests + register + seed + full Playwright e2e against the running stack |

## Upgrading container versions

Use the `/upgrade-stack` skill (`.claude/skills/upgrade-stack/SKILL.md`) — the
per-cycle runbook: discover releases, changelog checklist, pin both layers,
clean start, `make verify`, UI `stack:verify`, report.

## Follow-ups (recorded, out of scope so far)

- Pin the four unpinned terraform add-on Helm charts
  (`terraform/modules/k8s-apps/main.tf`).
- Stack e2e stays local-only (CI builds images and lints the chart, but the
  full compose e2e needs the gitignored license/JAR).
