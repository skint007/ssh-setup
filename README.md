# ssh-setup

A single Bash script that automates the full "set up key-based SSH access to a host" workflow:

1. Generates a dedicated SSH key pair for the target host.
2. Installs the public key on the server (`ssh-copy-id`, with a manual fallback).
3. Adds a matching `Host` entry to `~/.ssh/config` (with a timestamped backup).
4. Tests the connection so you know it worked.

After running it once per host, you connect with a short alias: `ssh myserver`.

It can also **rotate** an existing key — generate a fresh one, install it, verify
it works, and remove the old key from the server — with a single command. See
[Rotating a key](#rotating-a-key).

Every key it creates or rotates is stamped with a date tag in the key comment
(`(created 2026-07-05)` / `(rotated 2026-07-05)`), and `--check-age` reads those
tags back to tell you which keys are due for rotation — and offers to rotate
them on the spot. See [Checking key ages](#checking-key-ages).

## Requirements

- Bash 4+
- `ssh` and `ssh-keygen` (OpenSSH)
- `ssh-copy-id` (optional — the script falls back to a manual copy if it's missing)

## Installation

```bash
chmod +x ssh-setup.sh
# optional: put it on your PATH
sudo install -m 755 ssh-setup.sh /usr/local/bin/ssh-setup
```

## Usage

```bash
./ssh-setup.sh --host <hostname> [options]
```

Only `--host` is required; everything else has a sensible default.

### Options

| Option | Description | Default |
| --- | --- | --- |
| `-h`, `--host` | Target hostname or IP address **(required)** | — |
| `-u`, `--user` | Username for the SSH connection | the local user |
| `--local-user` | Local account to install the key and config for (see [Installing for another user](#installing-for-another-user)) | the user running the script |
| `-p`, `--port` | SSH port | `22` |
| `-n`, `--name` | Key name identifier (used in the key filename) | the host |
| `-c`, `--comment` | Comment embedded in the SSH key | `user@localhost_to_host` |
| `-t`, `--type` | Key type: `ed25519`, `rsa`, or `ecdsa` | `ed25519` |
| `-b`, `--bits` | Key size **for RSA keys only** | `4096` |
| `--alias` | `Host` alias written to `~/.ssh/config` | the host |
| `--rotate` | Rotate the key of an existing entry instead of creating one (see [Rotating a key](#rotating-a-key)) | — |
| `--check-age` | List managed keys by age and offer to rotate old ones (see [Checking key ages](#checking-key-ages)) | — |
| `--max-age` | Days before a key counts as due for rotation (with `--check-age`) | `90` |
| `--help` | Show usage and exit | — |

> **Note:** `-h` means `--host`, not help. Use `--help` for the usage message.

### Examples

```bash
# Minimal: key + config for example.com as your current user
./ssh-setup.sh --host example.com --user myuser

# Custom port and a friendly key name for a home server
./ssh-setup.sh -h 192.168.1.100 -u admin -p 2222 -n homeserver

# A dedicated key + "github" alias for GitHub
./ssh-setup.sh --host github.com --user git --alias github --name github

# An RSA key instead of ed25519
./ssh-setup.sh --host legacy.example.com --user ops --type rsa --bits 4096

# Rotate the key for an existing entry
./ssh-setup.sh --rotate --alias homeserver

# List all managed keys by age; offer to rotate any older than 180 days
./ssh-setup.sh --check-age --max-age 180

# As root, set up SSH access for skint007 instead of root
sudo ./ssh-setup.sh --host example.com --local-user skint007
```

## Installing for another user

Sometimes the account you're logged in as isn't the account that should own the
key — e.g. you're provisioning a machine as `root` but want SSH access set up
for `skint007`. Pass `--local-user`:

```bash
sudo ./ssh-setup.sh --host example.com --local-user skint007
```

With `--local-user <name>`, the script **re-execs itself as that user** (via
`runuser`) after checking you're root and the account exists. Everything after
that point runs as the target user, so:

- The key pair, `config` entry, and config backups land in **that user's**
  `~/.ssh` and are owned by them — no `chown` step, nothing left root-owned.
- `ssh` resolves *their* `~/.ssh/config`, `known_hosts`, identities and agent —
  the install, verification, and final connection test all use the exact setup
  they'll use when they later run `ssh <alias>`.
- The remote username (`--user`) defaults to the local user, not to `root`.
- `--rotate` works the same way: `sudo ./ssh-setup.sh --rotate --alias
  homeserver --local-user skint007` rotates the entry in that user's config.

Running with a `--local-user` other than yourself requires root and
`runuser` (part of `util-linux`, present on essentially all Linux systems).
The target user must be able to read the script file, since it is re-run as
them. Without the flag, behavior is unchanged — everything happens in your own
`~/.ssh` with no re-exec.

## Rotating a key

Rotate the key of an entry you previously created:

```bash
./ssh-setup.sh --rotate --alias homeserver   # or: --host <name>
```

You only name the entry — its `HostName`, `User`, `Port`, and `IdentityFile` are
read back from `~/.ssh/config`, and the new key is generated to **match the old
key's type and size** (ed25519 / rsa / ecdsa). The process is ordered so a
failure can never lock you out:

1. Generate a new key alongside the old one (comment carried over, tagged
   `(rotated <date>)`).
2. Install the new public key on the server — authenticating with the **old**
   key for a seamless, non-interactive copy (falling back to `ssh-copy-id` or a
   password prompt if the old key no longer works).
3. **Verify the new key authenticates** — and only then proceed. If it doesn't,
   the rotation aborts, the old key is left fully intact, and the temporary new
   key is removed.
4. Delete the old local key and move the new key into the original filename — so
   the entry's `IdentityFile` needs no edit. The comment line heading the `Host`
   block is refreshed to `(rotated <date>)`, so the config itself shows when the
   key was last rotated.
5. Remove the old public key from the server's `authorized_keys`.

The old key is only deleted **after** the new key is confirmed working, so a
failed rotation never costs you the old key. Because the new key reuses the old
key's filename, your `Host` entry and the `ssh <alias>` command keep working
unchanged. Once rotation completes, the old key no longer grants access anywhere
— it's gone locally and removed from the server.

> **Note:** FIDO/hardware-backed keys (`sk-ssh-ed25519`, `sk-ecdsa-*`) can't be
> rotated by this script and are reported as such. If the old key has a
> passphrase and isn't loaded in an agent, the old-key auth step falls back to
> `ssh-copy-id`/password.

### Rotating a GitHub key

GitHub gives you no shell, so the `authorized_keys` steps above don't apply to it.
When a `Host` entry resolves to `github.com` (or a `*.github.com` host such as
`ssh.github.com`), rotation is automatically driven through the **GitHub API via
the [`gh`](https://cli.github.com/) CLI** instead:

1. Generate the new key (same type/size), exactly as above.
2. **Add** the new public key to your account with `gh ssh-key add`.
3. **Verify** it works with `ssh -T git@github.com` — matched on GitHub's
   *"successfully authenticated"* banner, since GitHub always closes the session
   with a non-zero exit status.
4. Swap the new key into the original filename (same as a normal rotation).
5. **Delete** the old key from your account with `gh ssh-key delete`, located by
   matching its public-key material via `gh api user/keys`.

This requires `gh` to be installed, authenticated (`gh auth login`), and to hold
the `admin:public_key` scope. If the scope is missing, rotation stops **before
generating anything** and tells you to grant it:

```bash
gh auth refresh -h github.com -s admin:public_key
```

> **Note:** only GitHub is handled this way. Other git hosts (GitLab, Bitbucket,
> Codeberg, self-hosted GitHub Enterprise) still use the `authorized_keys` path
> and would need their own web UI/API for key rotation.

## Checking key ages

Every key the script creates or rotates carries a date tag in its comment —
`(created 2026-07-05)` or `(rotated 2026-07-05)` — stored in the `.pub` file,
so the age travels with the key itself (no separate state file to lose, and
the tag is even visible in the server's `authorized_keys`). Rotation replaces
the tag rather than stacking a new one each time.

`--check-age` walks every `Host` entry in `~/.ssh/config` that has an
`IdentityFile`, reports each key's age, and offers to rotate the old ones:

```bash
./ssh-setup.sh --check-age                 # due after 90 days (default)
./ssh-setup.sh --check-age --max-age 180   # custom threshold
```

```text
[INFO] Checking key ages (rotation due after 90 days):

  HOST                 CREATED         AGE  STATUS         KEY
  homeserver           2025-12-17     200d  rotation due   /home/me/.ssh/id_ed25519_homeserver
  github               2026-06-20      15d  ok             /home/me/.ssh/id_ed25519_github

[WARNING] 1 key(s) due for rotation.
Rotate 'homeserver' now? (y/N):
```

Answering `y` runs the normal [rotation flow](#rotating-a-key) for that entry —
including the [GitHub path](#rotating-a-github-key) when the entry points at
`github.com`. A rotation that fails (e.g. the host is unreachable) is reported
and the batch continues on to the remaining keys. Keys made before this feature
existed (no date tag in the comment) fall back to the private key file's
modification time, which is accurate for any key this script generated or
rotated. Glob entries (`Host *.example.com`) are skipped.

## What it creates

For a host named `example.com` with the default `ed25519` type:

- **Private key:** `~/.ssh/id_ed25519_example.com` (mode `600`)
- **Public key:** `~/.ssh/id_ed25519_example.com.pub` (mode `644`)
- **Config entry** appended to `~/.ssh/config`:

  ```ssh-config
  # myuser@laptop_to_example.com (created 2026-07-05)
  Host example.com
      HostName example.com
      User myuser
      Port 22
      IdentityFile /home/myuser/.ssh/id_ed25519_example.com
      IdentitiesOnly yes
  ```

Key filenames follow the pattern `id_<type>_<name>`, so each host gets its own
key and you can revoke access to one host without affecting the others.

`IdentitiesOnly yes` ensures only this key is offered for the host, avoiding
"too many authentication failures" errors when you have many keys loaded.

## Behavior & safety

- **Keys are generated without a passphrase** (`-N ""`) so connections are
  non-interactive. If you want a passphrase, generate the key manually or add
  one afterwards with `ssh-keygen -p -f <keyfile>`.
- **Existing key files** prompt before being overwritten.
- **`~/.ssh/config` is backed up** to `~/.ssh/config.backup.<timestamp>` *only*
  immediately before it is modified, at most once per run — declining a change
  leaves no clutter, and a `--check-age` run that rotates several keys leaves a
  single backup of the pre-run state.
- **Re-running for an existing alias** prompts before replacing it. The old
  block is removed cleanly (including its leading comment) before the new one is
  appended, so the config doesn't accumulate stale or duplicate entries.
- **Alias matching is exact**, so glob-style aliases (e.g. `*.example.com`) and
  multi-alias `Host` lines are handled correctly.
- **Rotation verifies the new key before removing the old one**, so an aborted
  rotation never leaves you locked out (see [Rotating a key](#rotating-a-key)).
- **`umask 077`** is set so any files the script creates are not world-readable.
- The script uses `set -euo pipefail` and aborts on the first real error.

## Connecting afterwards

```bash
ssh example.com        # uses the alias from ~/.ssh/config
ssh -v example.com     # verbose, for debugging
```

## Troubleshooting

- **"SSH connection test failed"** at the end is a *warning*, not necessarily a
  failure — some servers reject the non-interactive (`BatchMode=yes`) test even
  though normal logins work. Try `ssh -v <alias>` to confirm.
- **`ssh-copy-id` failed, trying manual method** — the script first tries
  `ssh-copy-id`; if that fails (or isn't installed) it appends the key over a
  normal SSH session, which will prompt for your password.
- **Permission denied after setup** — verify the server allows public-key auth
  (`PubkeyAuthentication yes` in `sshd_config`) and that the remote
  `~/.ssh`/`authorized_keys` permissions are `700`/`600`.
