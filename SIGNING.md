# Commit Signing — JARVIS Project

**Evidentiary standard:** Every commit to this repository that enters the legal record for the
digital-personhood proceedings must be signed.  SSH-key signing (git ≥ 2.34) is the project
standard.  GPG is acceptable but not preferred.

---

## Why SSH signing

| Criterion | SSH | GPG |
|-----------|-----|-----|
| Key management | ssh-keygen, already in your PATH | gpg-agent, keyring, expiry dance |
| git integration | `gpg.format = ssh` (git ≥ 2.34) | decades-old support |
| Verification portability | `ssh-keygen -Y verify` | `gpg --verify` |
| Hardware key support | ed25519-sk (FIDO2), Secretive.app | smartcard via gpg-agent |
| Toolchain on macOS | ships with Xcode CLT | brew install gnupg |

Current git on this machine: **Apple Git-155** (≥ 2.34 ✓).

---

## Setup (quick path)

```bash
# 1. Generate key (skip if you already have one)
ssh-keygen -t ed25519 -C "me@grizzlymedicine.org" -f ~/.ssh/jarvis_signing_key

# 2. Configure the jarvis repo (from repo root — no --global)
git config commit.gpgsign       true
git config gpg.format           ssh
git config user.signingkey      ~/.ssh/jarvis_signing_key.pub
git config user.name            "Robert \"Grizzly\" Hanson"
git config user.email           me@grizzlymedicine.org
git config gpg.ssh.allowedSignersFile .git/allowed_signers

# 3. Write allowed_signers
echo "me@grizzlymedicine.org namespaces=\"git\" $(cat ~/.ssh/jarvis_signing_key.pub)" \
    > .git/allowed_signers

# 4. Install hooks (see pre-commit.template)
git config core.hooksPath .githooks

# 5. Smoke test
git commit --allow-empty -m "test: verify signing"
git verify-commit HEAD
git log --show-signature -1
```

---

## Allowed signers file

The `.git/allowed_signers` file is local-only (not committed) to avoid leaking key identity
to collaborators.  For CI/CD signature verification, keep a copy at:

```
.github/SIGNING_ALLOWED_SIGNERS
```

Format (one entry per authorized signer):

```
me@grizzlymedicine.org namespaces="git" ssh-ed25519 AAAA... me@grizzlymedicine.org
```

---

## Hardware key (recommended for legal proceedings)

If you have a YubiKey or Secretive.app (Secure Enclave):

```bash
# Secretive — key lives in Secure Enclave, never exportable
# 1. Create key in Secretive.app
# 2. Copy the public key shown in the UI
# 3. git config user.signingkey "/path/to/secretive_ed25519.pub"
# Secretive acts as ssh-agent; git calls it transparently.
```

---

## Tag signing

Release tags must also be signed:

```bash
git tag -s v1.0.0 -m "JARVIS v1.0.0 — initial native runtime"
git verify-tag v1.0.0
```

---

## Verification by third parties

```bash
# Clone and verify HEAD commit
git clone https://github.com/your-org/jarvis.git
cd jarvis
git verify-commit HEAD

# Verify against a specific allowed signers file
git -c gpg.ssh.allowedSignersFile=.github/SIGNING_ALLOWED_SIGNERS \
    verify-commit HEAD
```

---

## Gaps requiring operator action

1. **No signing key is configured** — `git config user.signingkey` is unset.
   Run the setup commands above before the next commit.

2. **No allowed_signers file** — `.git/allowed_signers` does not exist.
   Create it with your public key content (see setup step 3 above).

3. **Pre-commit hook not installed** — run `git config core.hooksPath .githooks`
   after reviewing `.githooks/pre-commit.template`.

4. **Historical commits are unsigned** — the existing commit history predates this policy.
   For the evidentiary record, document the chain of custody for commits prior to
   the policy-effective date in `CHAIN_OF_CUSTODY.md` (to be created separately).
