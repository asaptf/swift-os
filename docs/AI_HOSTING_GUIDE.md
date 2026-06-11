# SwiftOS AI Hosting Guide

This guide explains the current AI hosting surface in SwiftOS: local TinyStories
inference, HTTP model serving, verified model bundles, health and metrics, and
the operational limits that matter when validating or extending the system.

Use it with:

- [Service Guide](SERVICE_GUIDE.md) for service lifecycle and readiness rules.
- [Operations Guide](OPERATIONS_GUIDE.md) for QEMU boot profiles and evidence.
- [Command Reference](COMMAND_REFERENCE.md) for exact `llm` and `llmd` syntax.
- [API Reference](API_REFERENCE.md) for file-backed `mmap`, sockets, and `poll`.
- [Performance And Sizing Guide](PERFORMANCE_GUIDE.md) for interpreting QEMU
  inference metrics and sizing evidence.
- [Deployment Guide](DEPLOYMENT_GUIDE.md) for AI hosting candidate artifacts,
  validation gates, and handoff evidence.
- [Support Guide](SUPPORT_GUIDE.md) for failure reports and support bundles.

## What Exists Today

SwiftOS ships a native Embedded Swift inference engine and two user-facing entry
points:

| Program | Purpose | Model path | Test |
| --- | --- | --- | --- |
| `/bin/llm` | Run one console completion and return to the shell | `/models/stories260K.bin` plus `/models/tok512.bin` | `./tests/llm_run_test.sh` |
| `/bin/llmd` | Serve completions over HTTP on TCP 8080 | Signed verified bundle rooted at `/models/stories15M` | `./tests/llm_serve_test.sh` |

Both programs are static EL0 binaries. The transformer and tokenizer live in
[userland/lib/llama2.swift](../userland/lib/llama2.swift). The serving daemon
also links the verified bundle parser in
[userland/lib/modelbundle.swift](../userland/lib/modelbundle.swift).

The current engine is a CPU TinyStories proof of application and AI hosting. It
is not a general ONNX, GGUF, PyTorch, or GPU runtime.

## Choose An AI Workflow

Pick the smallest workflow that proves the question you are asking:

| Need | Use this path | What it proves | Minimum proof |
| --- | --- | --- | --- |
| Verify local model files and the inference core | `/bin/llm` | The small fp32 TinyStories model and tokenizer can mmap, tokenize, generate, and return to the shell | `./tests/llm_run_test.sh` |
| Verify HTTP serving | Default `/bin/llmd` | The Q8_0 serving model binds TCP 8080, answers `/completion`, and exposes `/health` plus `/metrics` | `./tests/llm_serve_test.sh` |
| Verify signed immutable bundles | Default `/bin/llmd` with `/models/stories15M` | Ed25519 manifest verification, payload SHA-256 checks, corrupt-generation rejection, and fallback to the newest valid generation | `./tests/llm_serve_test.sh`, `build/llm_bundle_test` |
| Experiment with raw model paths | `/bin/llmd /models/stories260K.bin /models/tok512.bin` | The server can load explicit model/tokenizer paths for development | Manual run plus serial startup markers |
| Prepare a deployment candidate | AI hosting profile in [Deployment Guide](DEPLOYMENT_GUIDE.md) | Model artifacts, base image hash, health responses, metrics, and rollback evidence are captured together | Deployment evidence bundle plus focused AI tests |

Use the verified bundle path for any handoff or release candidate. Raw model
overrides are development tools and do not prove manifest signature or payload
hash enforcement.

## Artifact Map

| Artifact | Built by | Staged as | Used by |
| --- | --- | --- | --- |
| `models/stories260K.bin` | `make model` | `/models/stories260K.bin` | `/bin/llm` |
| `models/tok512.bin` | `make model` | `/models/tok512.bin` | `/bin/llm` and optional raw `llmd` runs |
| `models/stories15M.bin` | `make model` | Host source only | Quantized into `stories15M-q8.bin` |
| `models/stories15M-q8.bin` | `make model` | `/models/stories15M/1/model.bin` | Default `/bin/llmd` |
| `models/tokenizer.bin` | `make model` | `/models/stories15M/1/tokenizer.bin` | Default `/bin/llmd` |
| `models/dev-signing.seed` | `make base-image` | Host signing seed, gitignored | Signs development manifests |
| `models/dev-signing.pub` | `make base-image` | `/etc/swos/model-signing.pub` | Guest trust root |
| `build/base.img` | `make base-image` | Read-only base image | Guest model storage |

Model files are intentionally not tracked in git. A fresh checkout needs
`make model` or `make base-image` to fetch and prepare them.

## Fresh Checkout Setup

Build the kernel, model artifacts, and base image:

```sh
make build
make model
make base-image
```

`make model` fetches the TinyStories checkpoints and tokenizer files, then
quantizes the larger served checkpoint into Q8_0 format. `make base-image`
stages `/bin/llm`, `/bin/llmd`, the small local model files, and the verified
serving bundle into `build/base.img`.

The full acceptance suite also covers the host inference core and bundle
helpers:

```sh
make test
```

For focused AI checks:

```sh
./tests/llm_run_test.sh
./tests/llm_serve_test.sh
/usr/bin/swiftc tests/llm_bundle_test.swift userland/lib/modelbundle.swift kernel/crypto/sha256.swift -o build/llm_bundle_test
build/llm_bundle_test
```

## Local Console Inference

Boot normally:

```sh
make run
```

Log in as `root` or another principal with filesystem read authority, then run:

```sh
/bin/llm
```

The default prompt is `Once upon a time` and the default generation length is 64
tokens. A shorter demonstration is:

```sh
/bin/llm "Once upon a time" 16
```

Expected markers:

```text
llm: weights mmap'd file-backed from /models
llm: stories260K dim=...
llm: generating ... tokens (greedy)
--- output ---
...
--- end ---
llm: ... tokens in ... ms (... tok/s)
llm: done
```

The focused test asserts that the generated text matches the pinned llama2.c
reference output and that the shell still works after the process exits.

## HTTP Model Serving

`/bin/llmd` is the current serving entry point. It binds guest TCP port 8080,
serves HTTP/1.0 responses, and closes each connection to delimit the body.

Boot with a virtio-net NIC and host TCP forwarding:

```sh
make build base-image build/virt.dtb

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

Log in as `root`; the seeded `root` principal has `capNet`.

Start the server:

```sh
/bin/llmd
```

Healthy startup logs:

```text
llmd: trust root loaded (/etc/swos/model-signing.pub)
llmd: generation 2 rejected (model size/sha256 mismatch)
llmd: bundle stories15M generation 1 verified (ed25519+sha256)
llmd: weights mmap'd file-backed from /models
llmd: model int8 Q8_0 GS=32 dim=288 vocab=32000
llmd: serving on 8080 (POST /completion, GET /health, GET /metrics)
```

The trust-root marker is expected in the checked-in image. Generation 2 has a
valid Ed25519 manifest signature but a deliberately corrupt model payload, so
the loader rejects it at the payload hash layer and falls back to the newest
generation that passes both signature and payload verification.

Host requests:

```sh
curl -fsS http://127.0.0.1:8080/health
curl -fsS -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
curl -fsS http://127.0.0.1:8080/metrics
```

`/bin/httpd` also uses guest TCP port 8080. Run either `httpd` or `llmd`, not
both at the same time.

## HTTP API

| Endpoint | Method | Request body | Response |
| --- | --- | --- | --- |
| `/health` | `GET` | None | Liveness and model shape |
| `/completion` | `POST` | Prompt text | Generated text |
| `/metrics` | `GET` | None | Serving counters and last request timing |

Example health response:

```text
ok model dim=288 layers=6 vocab=32000
```

Example completion request:

```sh
curl -fsS -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
```

The server streams decoded token pieces as they are produced. The response is
plain text and is complete when the HTTP/1.0 connection closes.

Example metrics response:

```text
requests 1
tokens_total 64
last_ttft_ms 80
last_tok_s 11
```

The serial log also records per-request serving metrics:

```text
llmd: served 64 tokens ttft=80 ms rate=11 tok/s
```

Treat the numeric values as environment-dependent. QEMU TCG performance depends
on the host, build artifacts, cold page faults, and scheduling.

## Verified Model Bundles

Default `llmd` startup resolves a bundle under:

```text
/models/stories15M
```

Bundle generations are numeric directories:

```text
/models/stories15M/<generation>/manifest.toml
/models/stories15M/<generation>/model.bin
/models/stories15M/<generation>/tokenizer.bin
```

The loader scans numeric generations newest-first. With
`/etc/swos/model-signing.pub` present, each manifest must carry a valid Ed25519
signature over every byte before its `[signature]` table. The selected
generation must also have model and tokenizer payloads whose sizes and SHA-256
hashes match the signed manifest. Bad generations are logged and skipped.

Manifest shape:

```toml
name = "stories15M"
generation = 1
format = "llama2c"

[file.model]
path = "model.bin"
sha256 = "<64 lowercase hex characters>"
size = 17101696

[file.tokenizer]
path = "tokenizer.bin"
sha256 = "<64 lowercase hex characters>"
size = 433869

[signature]
algo = "ed25519"
sig = "<128 lowercase hex characters>"
```

Payload paths must be bare filenames. Paths containing `/` are rejected by the
loader to prevent a manifest from escaping its generation directory.

The host manifest generator is:

```sh
swiftc -O tools/modelmanifest.swift kernel/crypto/sha256.swift -o build/modelmanifest
build/modelmanifest stories15M 1 models/stories15M-q8.bin models/tokenizer.bin build/manifest.toml
```

The host signing tool is:

```sh
swiftc -O tools/modelsign.swift userland/lib/modelbundle.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift kernel/crypto/sha256.swift -o build/modelsign
build/modelsign keygen models/dev-signing.seed models/dev-signing.pub
build/modelsign sign build/manifest.toml models/dev-signing.seed
build/modelsign verify build/manifest.toml models/dev-signing.pub
```

The Makefile uses the same generator and signer while building `build/base.img`.
The public key ships in the guest as `/etc/swos/model-signing.pub`; the manifest
does not carry the trust root.

## Raw Model Override

For experiments, `llmd` can bypass the verified bundle and load explicit paths:

```sh
/bin/llmd /models/stories260K.bin /models/tok512.bin
```

Raw overrides are useful for development, but they do not perform manifest
signature or payload-hash verification. The loader still detects supported
checkpoint formats at runtime.

Supported model families today:

| Format | Use | Notes |
| --- | --- | --- |
| llama2.c fp32 checkpoint | `/bin/llm`, raw `llmd` experiments | Small `stories260K` inference path |
| llama2.c version 2 Q8_0 checkpoint | Default `/bin/llmd` | Groupwise int8 quantized path |

Unsupported today:

- GGUF.
- ONNX.
- PyTorch model files.
- Dynamic model runtime loading.
- GPU or accelerator execution.

## Adding A Checked-In Serving Bundle

Current SwiftOS does not have target-side model installation. To add or replace
a serving bundle in this repository revision, stage it into the base image or a
read-only package payload from the host side.

The checked-in default bundle is staged by `make base-image`:

1. Create `/models/stories15M/1`.
2. Copy the Q8 model to `model.bin`.
3. Copy the tokenizer to `tokenizer.bin`.
4. Generate `manifest.toml`.
5. Sign `manifest.toml`.
6. Stage the public key as `/etc/swos/model-signing.pub`.
7. Optionally add a newer generation to prove fallback or upgrade behavior.

For a new bundle name, keep the same shape:

```text
/models/<name>/<generation>/{manifest.toml,model.bin,tokenizer.bin}
```

Then update the serving default in [userland/llmd.swift](../userland/llmd.swift)
or pass explicit paths while developing. Raw path overrides bypass both manifest
signature and payload-hash verification.

## Security And Exposure

Network serving requires `capNet`; the seeded `root` principal has it. The
seeded `user` and `guest` principals do not.

Operational security properties today:

- The default model files live in the immutable read-only base image.
- The serving bundle manifest is verified with Ed25519 when the trust root is
  provisioned, and payloads are checked by size and SHA-256 before use.
- `llmd` runs as an EL0 process in its own address space.
- The QEMU examples bind host forwarding to `127.0.0.1`.

Limits to account for:

- There is no HTTPS listener in `llmd`.
- There is no authentication or authorization on the HTTP endpoint.
- There is no service manager, restart policy, or background supervisor yet.
- The checked-in bundle path has a single development trust root. Key rotation,
  multiple trust roots, revocation, and production signing policy are future
  work.
- Production certificate stores and long-running TLS service policy are future
  work.

For validation, keep host forwarding loopback-only unless you deliberately place a
separate trusted front end in front of QEMU.

## Performance Notes

The current path is intentionally small and deterministic:

- CPU inference only.
- Greedy generation.
- Default `llmd` generation length of 64 tokens.
- File-backed `mmap` of immutable model payloads.
- Q8_0 int8 serving model for the default daemon.
- Poll-driven TCP serving, with generation running inline.

Under QEMU TCG, throughput is a correctness signal, not a product performance
claim. The first served request can be colder because model pages are faulted in
from the base image as they are touched.

Use `/metrics` and the serial `llmd: served ...` line for relative comparisons
inside the same host and build setup.

## Troubleshooting

If `/bin/llm` cannot load model files:

```sh
make model
make base-image
./tests/llm_run_test.sh
```

If `/bin/llmd` cannot verify a serving generation, confirm these files exist in
the base image staging tree or guest:

```text
/models/stories15M/1/manifest.toml
/models/stories15M/1/model.bin
/models/stories15M/1/tokenizer.bin
```

If host requests cannot connect:

1. Confirm QEMU was launched with `hostfwd=tcp:127.0.0.1:8080-:8080`.
2. Confirm the guest session is `root` or another principal with `capNet`.
3. Confirm `llmd: serving on 8080` appeared before running `curl`.
4. Confirm no other service, such as `/bin/httpd`, is already bound to guest
   TCP 8080.

If generation is slow, that is expected under QEMU TCG. Run the focused tests to
separate expected slowness from functional failure:

```sh
./tests/llm_run_test.sh
./tests/llm_serve_test.sh
```

More failure patterns are documented in
[Troubleshooting](TROUBLESHOOTING.md#llm-inference-problems).

## Evidence Checklist

For AI hosting support reports, include:

- Repository commit.
- Host architecture and QEMU version.
- Exact QEMU command.
- Serial log from startup through the failed request.
- Output of `/health`, `/completion`, and `/metrics` when applicable.
- `./tests/llm_run_test.sh` and `./tests/llm_serve_test.sh` results.
- Any custom model path, tokenizer path, manifest, or bundle layout.

The support bundle workflow is in [Support Guide](SUPPORT_GUIDE.md).

## Roadmap Boundary

The current AI hosting surface proves the OS primitives needed by larger
application hosting work:

- isolated EL0 inference;
- file-backed model mappings;
- static userland services;
- network serving through capability-gated sockets;
- health and metrics endpoints;
- signed verified immutable model bundles.

Future work includes service supervision, package-managed model deployment,
production signing policy and revocation, production TLS policy, accelerator
service models, native Swift application hosting, and eventually Node.js and JVM
runtime support as tracked in [Architecture](ARCHITECTURE.md) and
[Risk Remediation Roadmap](RISK_REMEDIATION_ROADMAP.md).
