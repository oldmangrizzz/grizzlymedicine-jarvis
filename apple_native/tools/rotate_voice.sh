#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: apple_native/tools/rotate_voice.sh <voice-file> <reason> --attestation-token <token.json> [--speaker-uuid <uuid>]

Rotates the JARVIS canonical voice baseline or adds an operator-attested speaker anchor baseline. No --force exists.
USAGE
}

if [[ $# -lt 2 ]]; then
  usage
  exit 2
fi

NEW_VOICE="$1"
REASON="$2"
shift 2
TOKEN="${JARVIS_OPERATOR_ATTESTATION_TOKEN:-}"
SPEAKER_UUID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --attestation-token)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      TOKEN="$2"
      shift 2
      ;;
    --speaker-uuid)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      SPEAKER_UUID="$2"
      shift 2
      ;;
    --force)
      echo "rotate_voice.sh: --force is not supported; operator attestation is mandatory" >&2
      exit 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$TOKEN" || ! -f "$TOKEN" ]]; then
  echo "rotate_voice.sh: refused: operator-attestation token is required" >&2
  exit 1
fi
if [[ ! -f "$NEW_VOICE" ]]; then
  echo "rotate_voice.sh: refused: voice file not found: $NEW_VOICE" >&2
  exit 1
fi

JARVIS_HOME="${JARVIS_HOME:-$HOME/.jarvis}"
SBOM="${JARVIS_VOICE_SBOM:-$JARVIS_HOME/sbom/voice-weights-baseline.json}"
AUDIT_LOG="${JARVIS_VOICE_AUDIT_LOG:-$JARVIS_HOME/integrity/audit/voice_integrity.audit.log}"
AUDIT_KEY="${JARVIS_VOICE_AUDIT_KEY:-$JARVIS_HOME/integrity/audit/voice_integrity.audit.key}"
NEW_HASH="$(shasum -a 256 "$NEW_VOICE" | awk '{print tolower($1)}')"

python3 - "$TOKEN" "$SBOM" "$NEW_HASH" "$REASON" "$AUDIT_LOG" "$AUDIT_KEY" "$SPEAKER_UUID" <<'PY'
import json, sys, time, pathlib, hmac, hashlib, secrets, struct, os

token_path, sbom_path, new_hash, reason, audit_log, audit_key, speaker_uuid = sys.argv[1:]
try:
    token = json.load(open(token_path, 'r', encoding='utf-8'))
except Exception as exc:
    print(f"rotate_voice.sh: refused: malformed attestation token: {exc}", file=sys.stderr)
    sys.exit(1)

allowed_operations = {'authorize_voice_weight_change', 'authorize_speaker_anchor_change'}
if token.get('operation_type') not in allowed_operations:
    print('rotate_voice.sh: refused: attestation token is not for voice or speaker anchor change', file=sys.stderr)
    sys.exit(1)
if token.get('subject_digest') != f'sha256:{new_hash}':
    print('rotate_voice.sh: refused: attestation token subject_digest does not match new voice hash', file=sys.stderr)
    sys.exit(1)
allowed_markers = {'OPERATOR_AUTHORIZED_VOICE_CHANGE', 'OPERATOR_AUTHORIZED_SPEAKER_ANCHOR_CHANGE'}
if token.get('marker') not in allowed_markers:
    print('rotate_voice.sh: refused: missing operator-authorized voice marker', file=sys.stderr)
    sys.exit(1)
if not token.get('signature_hex') and token.get('status') != 'operator_attestation_valid':
    print('rotate_voice.sh: refused: token does not carry a valid operator-attestation result', file=sys.stderr)
    sys.exit(1)

sbom_file = pathlib.Path(sbom_path)
sbom = json.load(open(sbom_file, 'r', encoding='utf-8'))
stamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
target_path = f'_local_voice/speakers/{speaker_uuid}.wav' if speaker_uuid else '_local_voice/jarvis_voice_state.safetensors'
source = 'operator-attested speaker enrollment' if speaker_uuid else 'operator-attested voice rotation'
for entry in sbom['entries']:
    if entry.get('path') == target_path:
        entry['sha256'] = new_hash
        entry['timestamp'] = stamp
        entry['reason'] = reason
        entry['source'] = source
        break
else:
    sbom['entries'].append({
        'path': target_path,
        'sha256': new_hash,
        'timestamp': stamp,
        'reason': reason,
        'source': source,
    })
sbom_file.write_text(json.dumps(sbom, indent=2) + '\n', encoding='utf-8')

def ensure_key(path):
    p = pathlib.Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists():
        data = p.read_bytes()
        if len(data) != 32:
            raise RuntimeError('audit key is not 32 bytes')
        return data
    data = secrets.token_bytes(32)
    fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    return data

def read_last_hash(path):
    p = pathlib.Path(path)
    if not p.exists():
        return bytes(32), 0
    seq = 0
    last = bytes(32)
    with p.open('rb') as f:
        while True:
            hdr = f.read(4)
            if len(hdr) == 0:
                return last, seq
            if len(hdr) != 4:
                return last, seq
            (n,) = struct.unpack('<I', hdr)
            payload = f.read(n)
            if len(payload) != n:
                return last, seq
            event = json.loads(payload.decode('utf-8'))
            last = bytes.fromhex(event.get('own_hash', '00'*32))
            seq = int(event.get('sequence_id', seq)) + 1

def lp(s):
    b = s.encode('utf-8')
    return struct.pack('<I', len(b)) + b

key = ensure_key(audit_key)
prev_hash, sequence = read_last_hash(audit_log)
event = {
    'sequence_id': sequence,
    'timestamp_ns': int(time.time_ns()),
    'event_kind': 'VOICE_BASELINE_ROTATED',
    'actor': 'operator',
    'subject': 'voice_weights',
    'outcome': 'allowed',
    'reason': 'VOICE_BASELINE_ROTATED' if not speaker_uuid else 'SPEAKER_ANCHOR_BASELINED',
    'redacted_metadata': json.dumps({'new_sha256': new_hash, 'reason': reason, 'timestamp': stamp, 'speaker_uuid': speaker_uuid, 'marker': token.get('marker')}, separators=(',', ':')),
    'prev_hash': prev_hash.hex(),
}
canonical = b''.join([
    struct.pack('<Q', event['sequence_id']),
    struct.pack('<Q', event['timestamp_ns'] & ((1<<64)-1)),
    lp(event['event_kind']), lp(event['actor']), lp(event['subject']),
    lp(event['outcome']), lp(event['reason']), lp(event['redacted_metadata']),
    prev_hash,
])
event['own_hash'] = hmac.new(key, canonical, hashlib.sha256).hexdigest()
payload = json.dumps(event, separators=(',', ':')).encode('utf-8')
pathlib.Path(audit_log).parent.mkdir(parents=True, exist_ok=True)
fd = os.open(audit_log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
try:
    os.write(fd, struct.pack('<I', len(payload)) + payload)
    os.fsync(fd)
finally:
    os.close(fd)
print((f'SPEAKER_ANCHOR_BASELINED {speaker_uuid} {new_hash}' if speaker_uuid else f'VOICE_BASELINE_ROTATED {new_hash}'))
PY
