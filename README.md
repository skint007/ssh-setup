# ssh-setup

A single Bash script that automates the full "set up key-based SSH access to a host" workflow:

1. Generates a dedicated SSH key pair for the target host.
2. Installs the public key on the server (`ssh-copy-id`, with a manual fallback).
3. Offers to set up a recommended `Host *` defaults block if you don't have one
   (see [Host \* defaults](#host--defaults)).
4. Adds a matching `Host` entry to `~/.ssh/config` (with a timestamped backup).
5. Tests the connection so you know it worked.

After running it once per host, you connect with a short alias: `ssh myserver`.

It can also **rotate** an existing key — generate a fresh one, install it, verify
it works, and remove the old key from the server — with a single command. See
[Rotating a key](#rotating-a-key).

Every key it creates or rotates is stamped with a date tag in the key comment
(`(created 2026-07-05)` / `(rotated 2026-07-05)`), and `--check-age` reads those
tags back to tell you which keys are due for rotation — and offers to rotate
them on the spot. See [Checking key ages](#checking-key-ages).

It can also **remove** a public key from a server's `authorized_keys` — the
inverse of `ssh-copy-id`, with a guard against locking yourself out. See
[Removing a key](#removing-a-key).

And it can **bootstrap** a brand new machine: run it from a machine that already
has access and it sets up a *different* machine's key access to your servers,
without ever copying a private key. See [Bootstrapping another machine](#bootstrapping-another-machine).

## Requirements

- Bash 4+
- `ssh` and `ssh-keygen` (OpenSSH)
- `ssh-copy-id` (optional — the script falls back to a manual copy if it's missing)
- For `--bootstrap`, the machine being set up needs a POSIX shell, `ssh`,
  `ssh-keygen`, `awk` and `mktemp` (the script itself isn't needed there)

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
| `--bootstrap` | Machine to set up access **for**, using this machine's access (see [Bootstrapping another machine](#bootstrapping-another-machine)) | — |
| `--hosts-file` | File of servers to bootstrap, one `[user@]host[:port]` per line | — |
| `--domain` | Domain suffix appended to any bare (dotless) server name | — |
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

# Give a brand new machine access to a server, from a machine that has access
./ssh-setup.sh --bootstrap newbox --host server1

# ...or to a whole fleet at once
./ssh-setup.sh --bootstrap newbox --hosts-file servers.txt --domain tail1234.ts.net

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

## Removing a key

The inverse of installing a key — delete a public key from a server's
`authorized_keys`. Useful after you've set up a dedicated key for a host and want
to stop a shared/default key from granting access there:

```bash
# Remove your default key (~/.ssh/id_ed25519.pub) from a host
ssh-setup --remove-key --host homeserver

# Target by config alias (reuses its HostName/User/Port and authenticates with
# the entry's own key), and remove a specific key file
ssh-setup --remove-key --alias homeserver --pubkey ~/.ssh/id_ed25519_old.pub

# Remove a key you only have as a string (e.g. one you spotted in authorized_keys)
ssh-setup --remove-key --host homeserver --key 'ssh-ed25519 AAAA...'
```

- **Matches on the key's base64 material**, so the comment doesn't matter and it
  can't remove the wrong line.
- **Refuses to remove the last remaining key** — the server won't empty its
  `authorized_keys`, so you can't accidentally lock yourself out.
- **Reports honestly**: `removed`, `key isn't present`, or `refused (only key)`.
- When you use `--alias`, it authenticates with that entry's key — so you're not
  relying on (or about to delete) the very key you're removing.

> ⚠️ Remove a shared/default key only **after** the host's dedicated key is set
> up and verified working — otherwise you may drop your last way in. There's no
> standard `ssh-remove-id`; this fills that gap.

## Bootstrapping another machine

`ssh-copy-id` needs an existing way in to the server. On a fleet with
`PasswordAuthentication no`, a brand new machine has no way in at all, so setting
up its access is a chicken-and-egg problem. The usual workaround — putting one
shared key on every server — is exactly what you don't want.

`--bootstrap` solves it from the other side. Run it on a machine that **already**
has working access, and it sets up a **different** machine's access:

```bash
# One server
ssh-setup --bootstrap newbox --host server1 --alias server1

# A whole fleet, one "[user@]host[:port]" per line in servers.txt
ssh-setup --bootstrap newbox --hosts-file servers.txt --domain tail1234.ts.net
```

For each server it:

1. **Generates the keypair on `newbox`** over SSH. The private key never leaves
   that machine — only the `.pub` travels.
2. **Installs the public key** in the server's `authorized_keys`, authenticating
   with *this* machine's existing working key.
3. **Writes the `Host` entry** in `newbox`'s `~/.ssh/config` (`IdentityFile` +
   `IdentitiesOnly yes`).
4. **Verifies** by having `newbox` itself connect to the server with the new key.

```
[INFO] Bootstrapping newbox -> root@server1:22 (alias 'server1')
[INFO] Host key for 'server1' verified against known_hosts.
[SUCCESS]   Key generated on newbox: ~/.ssh/id_ed25519_server1
[SUCCESS]   Public key added to root@server1:22
[SUCCESS]   SSH config entry 'server1' written on newbox
[SUCCESS]   Verified: newbox can now 'ssh server1'
```

Details worth knowing:

- **No private key is ever copied**, so a bootstrap can't leak one machine's
  identity onto another.
- **Server details come from your own config**, resolved with `ssh -G` — the same
  answer ssh itself would use, so wildcard blocks (`Host *.example.com`) and
  `Match` rules count, not just exact aliases. The resolved
  `HostName`/`User`/`Port` are what gets written on the new machine, and ssh
  connects by name so that entry's identity, `ProxyJump`, etc. still apply.
  Explicit values win: a spec's `user@`/`:port` first, then `--user`/`--port`,
  then the config.
- **The alias** is `--alias` for a single server, or the short name (first label)
  of each server in a batch. `--domain` appends a suffix to bare names, so a
  hosts file can list `server1`, `server2`, … instead of full FQDNs. If two
  servers in a batch would shorten to the same alias (`web.prod.x` and
  `web.staging.x`), the run stops before touching anything.
- **Idempotent.** An existing key on the new machine is reused, the
  `authorized_keys` append matches on the key's base64 material (not the whole
  line, so a different comment isn't a duplicate), and the config entry is
  replaced rather than appended again. Re-running a batch after fixing one
  offline host is safe.
- **Fails per host, not per run.** One unreachable server doesn't stop the batch;
  a summary at the end lists what worked and what didn't, and the exit status is
  non-zero if anything failed.
- **A symlinked `~/.ssh/config` stays a symlink.** These are often links into a
  dotfiles repo, so the new content is written *through* the link instead of
  replacing it with a regular file (which would orphan the dotfiles copy). The
  config is backed up once per run before the first write.
- **Entries go above any `Host *` block**, same first-match-wins reasoning as the
  local path.
- **The verification runs `ssh <alias>` on the new machine** — the exact command
  you'll use — and checks which account it lands on. A direct `-i key user@host`
  probe would bypass the entry that was just written, so an earlier `Host`/`Match`
  rule shadowing it (SSH is first-match-wins) would go unnoticed. It also passes
  `-o ControlPath=none`, because with `ControlMaster auto` an already-open
  multiplexed session makes a broken key look like it works.
- **A server reached through a `ProxyCommand` is refused up front** rather than
  left with a key it can't use — that command line belongs to *this* machine. A
  `ProxyJump` is carried into the written entry, with a warning that the new
  machine needs its own access to the jump host.
- **The new machine is reached over a control socket this run creates**, so you
  authenticate to it at most once even for a fleet of servers — password auth to
  the new machine is fine.
- **Both ends get the host-identity check.** The machine being bootstrapped is
  checked *before* any remote command runs on it — otherwise a name that resolved
  to the wrong box could hand back a public key that then gets installed across
  the whole fleet — and each server is checked before anything is written to it
  (see [Behavior & safety](#behavior--safety)).
- **The machine is checked for `ssh`, `ssh-keygen`, `awk` and `mktemp` up front**,
  so a missing package can't leave keys installed on servers it can't use.

Once a machine is bootstrapped, any shared key you used to get this far is
redundant — remove it with
[`--remove-key`](#removing-a-key).

## What it creates

For a host named `example.com` with the default `ed25519` type:

- **Private key:** `~/.ssh/id_ed25519_example.com` (mode `600`)
- **Public key:** `~/.ssh/id_ed25519_example.com.pub` (mode `644`)
- **Config entry** added to `~/.ssh/config` (above any `Host *` catch-all):

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

## Host \* defaults

During setup, the script checks for a universal `Host *` catch-all block and
offers to create it (or fill in anything missing) — always behind a `y/N`
prompt. This matters most if you run scripts that open **many SSH connections in
quick succession**: without connection multiplexing, the server can rate-limit or
temporarily lock you out (`MaxStartups`). The recommended block is:

```ssh-config
Host *
    ConnectTimeout 15
    ServerAliveInterval 10
    ServerAliveCountMax 2
    StrictHostKeyChecking no
    ControlMaster auto
    ControlPath /tmp/ssh-%r@%h:%p
    ControlPersist 300
```

- **`ControlMaster` / `ControlPath` / `ControlPersist`** multiplex repeated
  connections over a single master socket (held open 5 min), so rapid-fire SSH
  doesn't hammer the server with full handshakes.
- **`ServerAlive*` / `ConnectTimeout`** keep long or idle sessions healthy and
  fail fast on unreachable hosts.
- **`StrictHostKeyChecking no`** auto-accepts host keys (convenient for
  automation; a security trade-off — drop this line if you'd rather confirm
  keys interactively).

If your `Host *` block already has all of these, the check stays silent. The
tool never edits the block without asking, and only ever *adds* missing lines —
it won't change values you've set.

> The script's own `ssh`/`ssh-copy-id` calls always pass `-o ControlPath=none`,
> so provisioning ignores any existing master socket and connects directly to
> the intended host — a stale master can't misdirect a key copy or verification.

## Behavior & safety

- **The target's host identity is verified before anything is generated or
  copied.** Setup reads the host key the target presents and compares it to
  `known_hosts`: a **changed** key aborts (with a hint that the name may have
  resolved to a different host — e.g. DNS wildcard fall-through — or the server
  was reinstalled), an **unknown** key shows the fingerprint + resolved IP and
  asks you to confirm, and a match proceeds quietly. Hosts on a non-default port
  are looked up as `[host]:port`, the way OpenSSH files them, so a changed key
  there is refused rather than mistaken for a first-time connection. This
  overrides an inherited
  `StrictHostKeyChecking no` for the check, so a name that silently resolves to
  the wrong box can't be handed your key. If the host is unreachable for the
  probe, the check is skipped rather than blocking setup.
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
  re-inserted, so the config doesn't accumulate stale or duplicate entries. A
  block runs until the next `Host`/`Match` line, so blank lines and comments
  inside a hand-formatted entry are removed with it rather than left behind —
  while a comment run directly above the *next* block is kept. A grouped
  `Host prod prod-admin` line keeps its other aliases; only the one being
  replaced is dropped.
- **Alias matching is exact**, so glob-style aliases (e.g. `*.example.com`) and
  multi-alias `Host` lines are handled correctly.
- **New entries are placed above a `Host *` catch-all** (rather than at the end
  of the file). SSH config is first-match-wins, so a specific entry appended
  below a catch-all that sets `User`/`IdentityFile`/`ProxyJump`/etc. could be
  silently shadowed by it; keeping specifics above `Host *` avoids that.
- **The script's own `ssh`/`ssh-copy-id` calls disable connection multiplexing**
  (`-o ControlPath=none`). If your `Host *` block enables `ControlMaster` +
  `ControlPersist`, a persisted master socket to the same name could otherwise
  tunnel the key copy or verification to whatever host that old connection points
  at — so provisioning always makes a fresh, direct connection to the real host.
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
