# scripts/demo — the landing page's recordings

Records and cuts the "See it run" clips in `site/media/`, from the real app on Sepolia. The
reshoot recipe is in `README.md`.

- **Never mock a clip.** Each is a recording of real Basecamp installs doing real
  transactions. The page says "Recorded, not drawn", and that claim has to stay true.
- **An edit list (`clips/*.json`) is the source of truth for a cut.** Raw takes live in
  `.run/demo/raw/` and stay out of git.
- **Keep every file under the repo's 1000 KB large-file limit.** Raise a clip's `crf`, or
  time-lapse its waits harder; do not exempt the file.
- **Stop recorders and servers by pid file** (`rec.sh stop`), never with `pkill -f <pattern>`.
  The pattern also matches the shell running the command, and kills it.
