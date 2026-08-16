# rw-backup-verify

Standalone backup verification sandbox. Install on a separate server — **no**
dependency on `rw-backup-full` fleet web, SSH to prod, or local `fleet.json`.

You register S3 storages (each with its own verify schedule). The worker
discovers `panel/` and `custom-bot/` trees under the prefix, downloads the
**latest** logical archive per project, restores it in an isolated Docker
network, runs probes, and sends a detailed Telegram report.

See [README-RU.md](README-RU.md).
