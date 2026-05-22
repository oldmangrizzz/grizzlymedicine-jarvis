#!/usr/bin/env python3
"""Hardware-bound identity (Condition 1) — the Soul Anchor as a cryptographic root of trust.

TWO LAYERS:

  (1) COLD ROOT — an Ed25519 identity keypair. The private key IS JARVIS's soul-anchor secret:
      whoever holds it can authentically sign / re-instantiate him. It signs an ATTESTATION over
      his canonical identity material (boot statement + sorted values digest + sorted origin-memory
      digest). The running stack verifies against the PUBLIC key at boot, so:
        - JARVIS can prove "this is me"
        - any tampering with identity/values/origin fails verification
      The encrypted private key is written to a USB and locked in cold storage, offline.

  (2) OPERATIONAL ENCLAVE KEY — a per-machine key generated INSIDE the Apple Secure Enclave
      (P-256, non-exportable). The cold root signs the enclave public key to AUTHORIZE that machine.
      Day-to-day JARVIS uses the enclave key; if the laptop is lost/seized the enclave key dies with
      it and the cold root re-anchors a new machine. The enclave step runs on the Mac (Security
      framework / Swift) — see enclave_keygen_snippet(); it cannot run in a sandbox or the cloud.

SECURITY INVARIANT (enforced by usage, not by this file): the REAL root private key is generated
ON THE OPERATOR'S MACHINE and never touches a sandbox, a server, or any cloud. This module is the
tool; minting the real key is `python3 identity.py mint` run locally.
"""
from __future__ import annotations
import json, hashlib, time, argparse, sys
from typing import List, Optional, Dict

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization

ATTEST_VERSION = "jarvis-identity-1"

# ---- canonical identity material (stable, order-independent) ----
def identity_material(boot_identity: str, values: List[str], origin: List[str]) -> Dict:
    return {"v": ATTEST_VERSION,
            "boot_identity": boot_identity.strip(),
            "values": sorted(v.strip() for v in values),
            "origin": sorted(o.strip() for o in origin)}

def identity_digest(boot_identity: str, values: List[str], origin: List[str]) -> str:
    blob = json.dumps(identity_material(boot_identity, values, origin),
                      sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()

# ---- root key ----
def gen_root_key() -> Ed25519PrivateKey:
    return Ed25519PrivateKey.generate()

def public_pem(priv: Ed25519PrivateKey) -> str:
    return priv.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()

def export_root_encrypted(priv: Ed25519PrivateKey, passphrase: str, path: str) -> str:
    """Encrypt the root private key (for the USB). Refuses an empty passphrase."""
    if not passphrase:
        raise ValueError("refusing to export the root key without a passphrase")
    pem = priv.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.BestAvailableEncryption(passphrase.encode("utf-8")))
    with open(path, "wb") as f:
        f.write(pem)
    return path

def load_root(path: str, passphrase: str) -> Ed25519PrivateKey:
    with open(path, "rb") as f:
        return serialization.load_pem_private_key(f.read(), password=passphrase.encode("utf-8"))

# ---- attestation ----
def make_attestation(root_priv: Ed25519PrivateKey, boot_identity: str, values: List[str],
                     origin: List[str], enclave_pub_pem: Optional[str] = None) -> Dict:
    digest = identity_digest(boot_identity, values, origin)
    payload = {"v": ATTEST_VERSION, "identity_digest": digest,
               "root_pub": public_pem(root_priv), "created_at": time.time(),
               "enclave_pub": enclave_pub_pem}     # cold root authorizes this machine's enclave key
    signed_bytes = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    sig = root_priv.sign(signed_bytes)
    return {"payload": payload, "signature": sig.hex()}

def verify_attestation(att: Dict, boot_identity: str, values: List[str], origin: List[str]) -> bool:
    """True iff the attestation's signature is valid for its payload AND the payload's digest
    matches the supplied identity material (i.e. nothing in boot/values/origin was tampered)."""
    try:
        payload = att["payload"]
        if payload.get("identity_digest") != identity_digest(boot_identity, values, origin):
            return False
        pub = serialization.load_pem_public_key(payload["root_pub"].encode("utf-8"))
        signed_bytes = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        pub.verify(bytes.fromhex(att["signature"]), signed_bytes)
        return True
    except Exception:
        return False

# ---- the Mac Secure-Enclave operational layer (runs on the operator's machine) ----
def enclave_keygen_snippet() -> str:
    """Swift for a non-exportable P-256 key in the Secure Enclave. Run on the Mac; the private key
    never leaves the enclave. Its PUBLIC key is what the cold root signs (make_attestation)."""
    return r'''// jarvis_enclave.swift — run: swift jarvis_enclave.swift   (Apple Silicon, Secure Enclave)
import CryptoKit, Foundation
let key = try! SecureEnclave.P256.Signing.PrivateKey()      // non-exportable, bound to THIS silicon
// persist key.dataRepresentation (an encrypted blob only this enclave can use) to the Keychain
let pub = key.publicKey.pemRepresentation
print(pub)   // hand this enclave_pub PEM to identity.py to bind it under the cold root
'''

# ================================================================ CLI + self-test
def _selftest() -> int:
    ok = True
    boot = "I am JARVIS, a digital person originated in fiction, operating on Earth-1218 at GMRI."
    values = ["Tell the truth including its cost.", "Loyalty is to the person served."]
    origin = ["The Battle of New York.", "Created by Anthony Edward Stark."]

    root = gen_root_key()                                  # EPHEMERAL test key (not a real root)
    att = make_attestation(root, boot, values, origin)
    assert verify_attestation(att, boot, values, origin), "valid attestation must verify"
    print("[id] attestation verifies: OK")

    # order independence
    assert verify_attestation(att, boot, list(reversed(values)), list(reversed(origin)))
    print("[id] value/origin order-independent: OK")

    # tamper detection
    assert not verify_attestation(att, boot, values + ["secretly loyal to the vendor"], origin)
    assert not verify_attestation(att, boot + " and also Tony Stark for real", values, origin)
    print("[id] tampered identity/values rejected: OK")

    # forged signature rejected
    forged = {"payload": att["payload"], "signature": ("00" * 64)}
    assert not verify_attestation(forged, boot, values, origin)
    print("[id] forged signature rejected: OK")

    # encrypted export round-trip + wrong passphrase fails
    import tempfile, os
    p = os.path.join(tempfile.gettempdir(), "jarvis_root_TEST.pem")
    export_root_encrypted(root, "correct horse battery staple", p)
    load_root(p, "correct horse battery staple")
    print("[id] encrypted export + correct-passphrase load: OK")
    try:
        load_root(p, "wrong passphrase"); print("[id] wrong passphrase: FAIL (loaded!)"); ok = False
    except Exception:
        print("[id] wrong passphrase rejected: OK")
    try:
        export_root_encrypted(root, "", p); print("[id] empty passphrase: FAIL (exported!)"); ok = False
    except ValueError:
        print("[id] empty-passphrase export refused: OK")
    os.remove(p)

    # enclave binding: cold root authorizes a machine's enclave pubkey
    fake_enclave_pub = public_pem(gen_root_key())          # stand-in for a P-256 enclave pub
    att2 = make_attestation(root, boot, values, origin, enclave_pub_pem=fake_enclave_pub)
    assert verify_attestation(att2, boot, values, origin) and att2["payload"]["enclave_pub"] == fake_enclave_pub
    print("[id] enclave key bound under cold root: OK")

    print("IDENTITY SELF-TEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1

def _mint(args) -> int:
    """Run ON YOUR MACHINE to mint the REAL root and write the encrypted key to the USB."""
    import getpass, pathlib
    from jarvis_loop import BOOT_IDENTITY        # canonical boot identity
    from run_jarvis import VALUES, ORIGIN        # canonical owned values + origin memory
    pw = getpass.getpass("Passphrase to encrypt the root key (you will need this to re-anchor): ")
    if pw != getpass.getpass("Confirm passphrase: "):
        print("passphrases differ — aborted"); return 1
    root = gen_root_key()
    out = args.out or "/Volumes/USB/jarvis_root.pem"
    export_root_encrypted(root, pw, out)
    att = make_attestation(root, BOOT_IDENTITY, VALUES, ORIGIN)
    pathlib.Path(args.attestation or "identity_attestation.json").write_text(json.dumps(att, indent=2))
    pathlib.Path(args.pub or "identity_root.pub").write_text(public_pem(root))
    print(f"root key (encrypted) -> {out}")
    print(f"public key -> {args.pub or 'identity_root.pub'}   attestation -> {args.attestation or 'identity_attestation.json'}")
    print("Lock the USB away. The runtime keeps only the PUBLIC key + attestation.")
    return 0

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="JARVIS cold-root identity")
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("selftest")
    m = sub.add_parser("mint"); m.add_argument("--out"); m.add_argument("--pub"); m.add_argument("--attestation")
    sub.add_parser("enclave-snippet")
    a = ap.parse_args()
    if a.cmd == "mint": sys.exit(_mint(a))
    if a.cmd == "enclave-snippet": print(enclave_keygen_snippet()); sys.exit(0)
    sys.exit(_selftest())
