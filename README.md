# benchmarkoor-tests

Configuration and orchestration repository for Ethereum execution client benchmarking. It defines the synthetic **state-actor** prestates, client configurations, test contexts, and GitHub Actions pipelines used to systematically benchmark execution-layer (EL) client implementations.

This repository coordinates with the [benchmarkoor](https://github.com/ethpandaops/benchmarkoor) runner to build prestates, fill test payloads, and execute performance tests.

## Supported Clients

- Geth
- Erigon
- Nethermind
- Besu
- Reth
- Ethrex

(Some contexts also define additional runner-only instances, e.g. Nimbus.)

## Overview

Benchmarks run against a synthetic **state-actor** prestate — a large, deterministically-generated datadir (EOAs, contracts, storage, delegations, predeploys) rather than a snapshot of a live network. The end-to-end flow is three separate GitHub Actions workflows:

1. **Build** — construct the state-actor datadir for a client (using `state-actor` builder images), then fill [EEST](https://github.com/ethereum/execution-spec-tests) benchmark payloads against it.
2. **Release** — promote the filled payloads from a build run into a GitHub Release.
3. **Run** — replay the payloads against the client and upload results to S3.

## Configuration

All configuration lives under `configs/`:

```
configs/
├── global.yaml                             # Global benchmarkoor settings
├── resource-limits-eip-7870-fullnode.yaml  # Hardware constraints (fullnode)
├── resource-limits-eip-7870-attester.yaml  # Hardware constraints (attester)
├── s3-upload.yaml                           # S3 results upload configuration
├── datadirs/
│   └── state-actor/v1/
│       ├── global.yaml                      # State-actor-wide settings
│       ├── builder.yaml                     # Prestate spec: entities, target_size, per-client builder images
│       └── runner.yaml                      # Datadir mount method (schelk) used by runs
└── contexts/
    └── repricing/v1/<subdir>/
        ├── global.yaml                      # Context-wide settings
        ├── clients.yaml                     # Per-client runner instances (image, extra args, genesis overrides)
        ├── test-source.<test-type>.builder.yaml   # How to FILL payloads (EEST ref, fork, gas values, filler images)
        └── test-source.<test-type>.runner.yaml    # Where a run FETCHES the filled payloads
```

A run is identified by the tuple `(snapshot, context, subdir, test-type, client, instance-id)`. Today `snapshot` is always `state-actor/v1` and `context` is always `repricing`; the variation is in `subdir`, `test-type`, and `client`. Each workflow assembles its config by fetching the files for that tuple from this repo, pinned to the dispatched commit (`github.sha`).

### Snapshot (state-actor prestate)

`snapshot` selects a prestate version under `configs/datadirs/<snapshot>/`. The only snapshot today is `state-actor/v1`. Its `builder.yaml` defines the prestate: the entities to generate (sequential EOAs, CREATE2 contract families, bloated storage, EIP-7702 delegations, EIP-8282 request predeploys, …), the target datadir size, and the per-client `state-actor` builder images. The datadir is materialized on build hosts and mounted into runs via schelk.

### Context & Subdir

The only **context** is `repricing` (gas-repricing / EIP-7870 scenarios). A **subdir** is a `v1/<name>` directory under it that groups a `clients.yaml`, `global.yaml`, and the `test-source.*` files. Subdir names track the fork / devnet variant:

| Subdir | Description |
|--------|-------------|
| `v1/bal-devnet-7` | BAL devnet-7 variant |
| `v1/glamsterdam-devnet-6` | Glamsterdam devnet-6 variant |
| `v1/glamsterdam-devnet-7` | Glamsterdam devnet-7 variant (`-m repricing` subset, 100M–300M gas sweep) |
| `v1/glamsterdam-devnet-7-full` | Glamsterdam devnet-7, full suite: no repricing marker, 200M/300M gas only, frozen `benchmarks/amsterdam` EEST ref |

### Test Types

| Type | Description |
|------|-------------|
| `stateful` | State-access benchmarks over the bloated state-actor prestate (bloatnet) |
| `compute` | Compute / precompile / instruction benchmarks |

Each test type has two test-source files:

- `test-source.<type>.builder.yaml` — used during a **build** to fill EEST payloads (EEST repo/ref, `fork`, `gas_benchmark_values`, `extract_opcode_count`, address stubs, and per-client filler images / extra args).
- `test-source.<type>.runner.yaml` — used during a **run** to fetch the filled payloads and replay them.

## Workflows

All workflows are `workflow_dispatch`-only and must be dispatched from the default branch. They fetch config from this repo pinned to the dispatched commit.

| Workflow | Purpose |
|----------|---------|
| `benchmarkoor-build.yaml` | Build the state-actor datadir **and** fill EEST payloads per client; upload per-client artifacts (consumed by release). |
| `benchmarkoor-build-state-actor.yaml` | Build **only** the state-actor datadir (no payload fill). Has a `force` input to rebuild over an already-populated/partial datadir. |
| `benchmarkoor-release.yaml` | Promote the filled payloads from a build run into a GitHub Release. |
| `benchmarkoor-run.yaml` | Build the datadir, replay the payloads, and upload results to S3. |

Common inputs: `clients` (JSON array), `snapshot`, `context`, `subdir`, `test-type`, and `instance-id`. `benchmarkoor-build-state-actor.yaml` takes only `snapshot` + `clients` (plus `force`), since the test context is irrelevant to a datadir-only build.

Config merge order:

- **build:** `global` → `datadirs/<snapshot>/{global,builder}` → `contexts/<context>/<subdir>/{global, test-source.<test-type>.builder}`
- **run:** `global` → resource-limits → `s3-upload` → `datadirs/<snapshot>/{global,runner}` → `contexts/<context>/<subdir>/{global, test-source.<test-type>.runner, clients}`

## Dispatchoor

The `dispatchoor/` directory holds generated job definitions for [dispatchoor](https://github.com/ethpandaops/dispatchoor) to trigger `benchmarkoor-run.yaml`.

`dispatchoor/generate.sh` produces one file per client (`benchmarkoor.<client>.yaml`) by scanning `configs/contexts/repricing/v1/*`. For each subdir it emits a dispatch entry per test type (`stateful`, `compute`) for that client's `<client>-bal-full` instance, targeting `benchmarkoor-run.yaml`. Subdirs with a `.dispatchoor_ignore` file are skipped.

Regenerate with:

```bash
make config
```
