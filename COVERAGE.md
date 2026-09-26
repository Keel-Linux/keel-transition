# Coverage of keel-transition

Standard: 95 percent of executed lines for code the project writes
(decision 0003), measured with bats under kcov (decision 0004). The
threshold lives in `tests/coverage.sh` (`COVERAGE_THRESHOLD`, default 95)
and in `.github/workflows/tests.yml`, so it is part of the review and not
of a dashboard.

```
bats tests/
tests/coverage.sh
```

Needs `bats`, `kcov`, `gnupg` and `gpgv`. Nothing the suite runs touches
the live system, needs root or reaches the network: every test works in a
scratch tree reached through `--root`, external commands (`curl`, `keel`,
`id`) are PATH stubs, and the OpenPGP keys are generated inside the test,
never the project key.

## Measured at the first release

2026-09-26, 94 tests, kcov 43 on Debian 13:

| File | Lines | Covered | Percent |
| --- | --- | --- | --- |
| `bin/keel-transition` | 3 | 3 | 100.00 |
| `lib/transition.sh` | 5 | 5 | 100.00 |
| `lib/common.sh` | 64 | 64 | 100.00 |
| `lib/archive.sh` | 25 | 25 | 100.00 |
| `lib/plan.sh` | 69 | 69 | 100.00 |
| `lib/phases.sh` | 152 | 152 | 100.00 |
| total | 318 | 318 | **100.00** |

Every exit code (0 to 8), every phase, every state of every file the tool
owns (absent, written by us, written by somebody else; the upstream list
enabled, disabled, both, absent) and every return of `archive_verify`
(verified, unsigned, signed by a foreign key, no keyring, no verifier)
has a test. The refusal, the byte for byte restore and the idempotence of
both `--apply` and `--rollback` are each asserted with `cmp` and
`diff -r`, not by reading output.

## What is not measured here

The packaging (`debian/rules` dearmoring the key and checking the
fingerprint) and the behaviour of the two `.deb` files on a real
appliance. Decision 0004 point 4: a build plus a run in a container is
the acceptance test and does not count toward this number. That run is
recorded in the repository's first pull request: a stock TurnKey Core
19.0 container, both packages installed, survey, the refusal, an apply
against an unsigned staging archive and a rollback with `/etc/apt`
restored byte for byte.
