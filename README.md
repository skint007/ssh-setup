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

With `--local-user <name>`:

- The key pair, `config` entry, and config backups are created under **that
  user's** `~/.ssh` (resolved via `getent`), and everything the script creates
  is `chown`ed to them.
- The remote username (`--user`) defaults to the local user, not to `root`.
- Host keys are recorded in that user's `~/.ssh/known_hosts`, so their first
  `ssh <alias>` won't hit a host-key prompt the script already answered.
- `--rotate` works the same way: `sudo ./ssh-setup.sh --rotate --alias
  homeserver --local-user skint007` rotates the entry in that user's config.

Running with a `--local-user` other than yourself requires root (it has to
write into their home and change ownership). Without the flag, behavior is
unchanged — everything happens in your own `~/.ssh`.

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
   `~/.ssh/config` needs no edit.
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

## What it creates

For a host named `example.com` with the default `ed25519` type:

- **Private key:** `~/.ssh/id_ed25519_example.com` (mode `600`)
- **Public key:** `~/.ssh/id_ed25519_example.com.pub` (mode `644`)
- **Config entry** appended to `~/.ssh/config`:

  ```ssh-config
  # myuser@laptop_to_example.com
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
  immediately before it is modified — declining a change leaves no clutter.
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
