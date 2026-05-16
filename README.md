# Forks MiSTer
Scripts and tasks for keeping MiSTer core forks synced with their upstreams.

### Github Actions

1. [Setup CI/CD](.github/workflows/setup_cicd.yml): Delivering CI/CD code to all forks repositories when necessary. Running on push/pull_request to this repository.
2. [Sync Forks](.github/workflows/sync_forks.yml): Scheduler every third hour, that cheks if the upstream has a newer release, and in that case tells the fork to sync with it.

### Scripts (Not intended for general use)

1. [`force_fork_release.sh`](force_fork_release.sh): Debugging script that forces a fork release.
2. [`force_forks_event.sh`](force_forks_event.sh): Debugging script that forces some event in this repository.
3. [`merge_joydb9md_into_main.sh`](merge_joydb9md_into_main.sh): Migration script that merges branch Joy_DB9MD into master for the given fork/s.
4. [`delete_branch_joydb9md.sh`](delete_branch_joydb9md.sh): Migration script that deletes the branch Joy_DB9MD from the given fork/s.
5. [`apply_replace_patch_1.sh`](apply_replace_patch_1.sh): Migration script that applies a replace patch to the given fork/s.
6. [`delete_latest_commit.sh`](delete_latest_commit.sh): Migration script that deletes the latest commit from the given fork/s.
7. [`sort_forks_ini.py`](sort_forks_ini.py): Script that keep Forks.ini sorted.
8. [`apply_db9_framework.sh`](apply_db9_framework.sh): Apply the MiSTer-DB9 fork framework (DB9/SNAC8 baseline + Saturn key-gate v1.5) to a core repo. Handles both pristine-upstream and legacy-patched `sys/` trees, lifts `<core>.sv` to the joydb wrapper-thin form, and ships the Saturn / SipHash / key-gate silicon.

### Porting helpers

The [`porting/`](porting/) directory ships the Python modules consumed by `apply_db9_framework.sh`:

- [`_eol_io.py`](porting/_eol_io.py): snapshot/restore line endings around `git apply` calls (which always lands LF and would mix endings on CRLF targets).
- [`upgrade_pro_additive.py`](porting/upgrade_pro_additive.py): walk a fork's `sys/` and add only the missing Pro extensions (saturn_unlocked, db9_key_gate include, USER_PP bits) on top of an existing legacy DB9 baseline, without resetting `sys/` from upstream.
- [`port_core_full.py`](porting/port_core_full.py): lift `<core>.sv` to the joydb wrapper-thin form (joy_type/joy_2p/saturn_unlocked, USER_PP, joy_raw + OSD_STATUS guard, Saturn-first CONF_STR).

## Instructions for Forks

- Every fork repository has to add the owner of this repository as [collaborator](https://help.github.com/en/github/setting-up-and-managing-your-github-user-account/inviting-collaborators-to-a-personal-repository).

- If a fork wants to enable email notification to the maintainer in case of merge conflict or compilation error, has to add a [Secret](https://help.github.com/en/actions/configuring-and-managing-workflows/creating-and-storing-encrypted-secrets) named `NOTIFICATION_API_KEY` with the proper auth key to the fork repository.

- Forks that ship the v1.5 key gate (Saturn unlock, future per-feature unlocks) must add a Secret named `MASTER_ROOT_HEX` containing the 32-byte SipHash root key as 64 hex chars. CI materialises it into `sys/db9_key_secret.vh` (FPGA cores) or `db9_key_secret.h` (Main_MiSTer HPS build) before each Quartus / `make` run via [`fork_ci_template/.github/materialize_secret.sh`](fork_ci_template/.github/materialize_secret.sh). Look for `[DB9-Key v1.5]` lines in the workflow log to confirm the secret was picked up; an unset/malformed secret leaves the build locked (every key file rejected) but does not fail the build.

- Every FPGA fork builds with native Quartus **Standard** (Quartus Lite is no longer used). The license is the existing organization Secret `QUARTUS_LICENSE` (FlexLM file; the node-lock MAC is derived from its `HOSTID=` automatically — no separate MAC secret is needed). The Standard version is picked automatically from the core's `.qsf` `LAST_QUARTUS_VERSION`; pin it explicitly with an optional `QUARTUS_NATIVE = <ver>std` (e.g. `17.0std`) line in the fork's `Forks.ini` section. Non-FPGA forks (`COMPILATION_INPUT = make`, e.g. Main_MiSTer) are unaffected — they keep their own gcc-arm pipeline.

- The fork needs to appear within [Forks.ini](Forks.ini) with the appropriate values in its declaration. In case it is desired to be synced it also has to be in the `SYNCING_FORKS` list.

### License

Copyright © 2020-2021, [José Manuel Barroso Galindo](https://github.com/theypsilon) for the [MiSTer-DB9 Team](https://github.com/MiSTer-DB9).
Released under the [GPL v3 License](LICENSE).
