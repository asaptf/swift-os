<!-- SPDX-License-Identifier: Apache-2.0 -->

## What and why

<!-- What changed, and what problem it solves. Link the issue or the milestone in
     docs/RISK_REMEDIATION_ROADMAP.md if there is one. -->

## How it was verified

<!-- Which gates you ran and what you saw. Paste the acceptance line from the
     serial log if the change has one (e.g. "S5 OK: ..."). -->

```
make build
make run
make test
# plus the focused gate for this area, e.g. make smp-test / nginx-test / c5-test
```

**Host:** <!-- macOS Apple Silicon / Linux, QEMU version -->

## Checklist

- [ ] It builds (`make build`) and still boots (`make run`).
- [ ] `make test` passes, plus the focused gate covering this change.
- [ ] The change ships an executable check (host unit test, QEMU boot assertion, or both).
- [ ] Swift by default — any new C/assembly is third-party code, a low-level bridge,
      or a toolchain limitation recorded in `docs/NOTES.md`.
- [ ] New source files carry the `SPDX-License-Identifier: Apache-2.0` header.
- [ ] Docs updated where this makes them stale (`docs/`, `README.md`).
- [ ] No dead or half-finished files, no unrelated reformatting.
