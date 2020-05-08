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

## Instructions for Forks

- Every fork repository has to add the owner of this repository as [collaborator](https://help.github.com/en/github/setting-up-and-managing-your-github-user-account/inviting-collaborators-to-a-personal-repository).

- If a fork wants to enable email notification to the maintainer in case of merge conflict or compilation error, has to add a [Secret](https://help.github.com/en/actions/configuring-and-managing-workflows/creating-and-storing-encrypted-secrets) named `NOTIFICATION_API_KEY` with the proper auth key to the fork repository.

- The fork needs to appear within [Forks.ini](Forks.ini) with the appropriate values in its declaration. In case it is desired to be synced it also has to be in the `SYNCING_FORKS` list.

### License

Copyright © 2020, [José Manuel Barroso Galindo](https://github.com/theypsilon).
Released under the [GPL v3 License](LICENSE).