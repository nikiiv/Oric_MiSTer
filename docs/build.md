# Building the Oric core

`tools/oric-build` is the one-stop script: it compiles the core in a
Quartus-in-Docker image and (optionally) pushes the resulting `.rbf`
to a MiSTer over SSH. Run it from the repo root.

## Prerequisites

| What                    | Why                                                          |
| ----------------------- | ------------------------------------------------------------ |
| `docker`                | Pulls/runs `raetro/quartus:mister` (Quartus 17.0.2 Lite).    |
| ssh + scp               | Needed only for deploy; talks to the MiSTer.                 |
| Reachable MiSTer        | Default target is hardcoded as `root@192.168.0.108`.         |

The Docker image is large (~6 GB) and gets pulled on first run.

## Quick start

```bash
# Compile + deploy to MiSTer (default)
./tools/oric-build

# Compile only, no deploy
./tools/oric-build --no-deploy

# Wipe Quartus build dirs first — slower, but the only safe option
# after big RTL refactors that confuse incremental compilation.
./tools/oric-build --clean

# Faster dev iteration: skip HDMI logic in the synthesis. Saves ~5 min.
./tools/oric-build --no-hdmi

# Snap loader debug: paint captured CPU regs at row 10 of the text
# screen after a snapshot load. Useful when chasing .sna restore bugs.
./tools/oric-build --snap-debug
```

Flags compose: `./tools/oric-build --clean --no-deploy --no-hdmi`.

Run with `-h` / `--help` to dump the usage block.

## What it does, step by step

1. **Sanity check** — bails out unless `Oric.qpf` is in the current
   working directory.
2. **Optional clean** — `rm -rf db incremental_db output_files` if
   `--clean`.
3. **Compile** — runs `quartus_sh --flow compile Oric.qpf` inside
   the Docker container, with the repo bind-mounted at `/build`. The
   container's UID/GID is mapped to the host user so generated files
   land owned by you, not root.
4. **Macro injection** — when `--no-hdmi` or `--snap-debug` is
   passed, the script writes a tiny TCL stub that does
   `set_global_assignment -name VERILOG_MACRO "FOO=1"` before the
   compile, then `git checkout -- Oric.qsf` afterwards so the dev
   macros never sneak into a commit.
5. **Output check** — fails if `output_files/Oric.rbf` is missing.
6. **Deploy** (unless `--no-deploy`):
   - SCPs the rbf to `${MISTER_DEV_DIR}/Oric_<YYYYMMDD_HHMMSS>_<sha>.rbf`
     (timestamped + short git SHA, so old builds don't get clobbered).
   - Also copies it to `${MISTER_DEV_DIR}/Oric.rbf` (stable dev "latest" name).
   - Removes previous `/media/fat/_Computer/Oric*.rbf` files and uploads
     `/media/fat/_Computer/Oric_<YYYYMMDD>.rbf` for the normal MiSTer
     computer-core launcher.

`MISTER_DEV_DIR` is `/media/fat/_Aoric` for fast development testing.
`MISTER_OFFICIAL_DIR` is `/media/fat/_Computer`, which is what `.mgl`
launchers refer to through `<rbf>_Computer/Oric</rbf>`.

Compile takes 15-40 minutes on a modern x86 box. The `--no-hdmi`
shortcut roughly halves that for iteration cycles.

## Changing the deploy target

Edit the `MISTER_HOST`, `MISTER_DEV_DIR`, and `MISTER_OFFICIAL_DIR`
vars at the top of the script:

```bash
MISTER_HOST="root@192.168.0.108"
MISTER_DEV_DIR="/media/fat/_Aoric"
MISTER_OFFICIAL_DIR="/media/fat/_Computer"
```

These aren't externalised because the script is a personal-workflow
tool, not a shared CI entry point — change in-place when your network
moves.

## Producing a release artifact

`oric-build` deploys a timestamped `.rbf` straight to the MiSTer, but
the in-repo `releases/` directory uses the convention
`Oric_YYYYMMDD.rbf` (date only, no SHA). The current pattern is to
build with `--no-deploy`, then copy `output_files/Oric.rbf` into
`releases/` with the date-stamped name and commit it. See the
`82f1ffd` commit for the shape.

## Troubleshooting

- **"unknown arg"** — typo'd a flag; only the four documented flags
  are accepted.
- **Permission errors on `db/` or `output_files/`** after a non-Docker
  Quartus run — `--clean` to wipe them, since Quartus may have
  written them as a different uid.
- **Compile passes but the MiSTer doesn't see the new core** — check
  that both deployment targets got refreshed:
  `ssh root@<host> ls -la /media/fat/_Aoric /media/fat/_Computer`.
- **Macros leaking into commits** — the script reverts `Oric.qsf` at
  the end; if a build is killed mid-flight, run `git checkout --
  Oric.qsf` manually before committing.
