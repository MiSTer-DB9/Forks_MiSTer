# Forks MiSTer
Scripts and tasks for keeping MiSTer core forks synced with their upstreams.

### Github Actions

1. [Setup CI/CD](.github/workflows/setup_cicd.yml): Delivering CI/CD code to all forks repositories when necessary. Running on push/pull_request to this repository.
2. [Sync Forks](.github/workflows/sync_forks.yml): Scheduler every third hour, that cheks if the upstream has a newer release, and it that case tells the fork to sync with it.

### Scripts

1. [`force_fork_release.sh`](force_fork_release.sh): Debugging script that forces a fork release. Not intended for general use.

## Instructions for Forks

- Every fork repository has to add the owner of this repository as [collaborator](https://help.github.com/en/github/setting-up-and-managing-your-github-user-account/inviting-collaborators-to-a-personal-repository).

- If a fork wants to enable email notification to the maintainer in case of merge conflict or compilation error, has to add a [Secret](https://help.github.com/en/actions/configuring-and-managing-workflows/creating-and-storing-encrypted-secrets) named `NOTIFICATION_API_KEY` with the proper auth key to the fork repository.

- The fork needs to appear within [Forks.ini](Forks.ini) with the appropriate values in its declaration. In case it is desired to be synced it also has to be in the `SYNCING_FORKS` list.
