# Provenance

Every file in this repository is **original work by Trung Dung Tran (lasttoss)**,
written from scratch, off employer time and equipment, with no employer code,
assets, configuration, or confidential data used.

Findings, measurements and conclusions were produced by running the lab on a
personal machine. The only third-party material included is:

| What | Where | License | Note |
|---|---|---|---|
| Nakama migration SQL (20 files) | `yb-migrations/*.sql` | Apache-2.0 | copied verbatim from `heroiclabs/nakama` tag `v3.41.0`, checksums in `yb-migrations/MANIFEST.sha256`; copyright The Nakama Authors |
| Container images referenced in compose files | `docker-compose*.yml` | Apache-2.0 / respective | pulled from public registries at runtime, not vendored |

No credentials, tokens, hostnames or client data from any employer or customer
are included. Addresses shown in docs are placeholders; the lab was run on
private IPs.
