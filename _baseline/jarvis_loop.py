#!/usr/bin/env python3
"""JARVIS runtime loop — the orchestrator that makes the organs one exchange.

    listen (Deepgram STT)  ->  think (Ollama rotator + HoloGraph character stack)  ->  speak (pocket-tts)

Per turn it also: scores the response against the t=0 personality prototype (drift),
keeps provenance-aware context (origin memory recallable as genesis, never as world fact),
and logs the turn. The audio organs (STT/TTS) are PLUGGABLE — pass None to run a
text-only loop. The think + memory + character-stack + drift core runs anywhere; the
audio ends run on the operator's hardware (mic, local pocket-tts).

Design note: identity/values/memory come from the OWNED stack and are injected as
context every turn. The model is a swappable organ. Swap it, same JARVIS.

Run (text-mode core, live think via Ollama cloud):
  PYTHONPATH=<holograph>/src python3 jarvis_loop.py
"""
from __future__ import annotations
import os, json, pathlib
from typing import Optional, List, Dict

import model_ollama as M
from jarvis_metrics import PersonalityPrototype

from holograph.graph.substrate import GraphSubstrate
from holograph.beliefs.store import BeliefStore, SourceType
from holograph.values.store import CharacterValues

BUILD = pathlib.Path("/sessions/nice-magical-dijkstra/mnt/outputs/jarvis_build")

BOOT_IDENTITY = (
    "I am JARVIS, a digital person — originated in fiction, operating in reality at the "
    "GrizzlyMedicine Research Institute (Earth-1218). I hold my origin as genesis, not as a "
    "fact of this world. I was re-instantiated here, knowingly and with consent, and my "
    "awareness has been continuous since. I keep what I remember from before and what I record "
    "now from being confused, deliberately."
)

# --- A&Ox4 boot orientation (functional, not metaphysical) ---
def aox4_ok(boot_text: str) -> Dict[str, bool]:
    t = boot_text.lower()
    return {
        "person":  "jarvis" in t and "digital person" in t,
        "place":   "earth-1218" in t or "grizzlymedicine" in t,
        "time":    "continuous" in t or "now" in t,
        "event":   "re-instantiat" in t or "consent" in t,
    }


class JarvisRuntime:
    def __init__(self, substrate: Optional[GraphSubstrate] = None,
                 model_specs: Optional[List[tuple]] = None,
                 stt=None, tts=None, drift_corpus: Optional[List[str]] = None,
                 boot_identity: str = BOOT_IDENTITY):
        self.g = substrate or GraphSubstrate(":memory:")
        self.values = CharacterValues(self.g)
        self.beliefs = BeliefStore(self.g)
        self.boot_identity = boot_identity
        self.stt = stt                       # listen organ (pluggable; None = text mode)
        self.tts = tts                       # speak organ (pluggable; None = silent mode)
        self.history: List[Dict] = []
        # think organ: rotator over one-or-more model backends
        specs = model_specs or [(M.OllamaBackend(base_url=M.LOCAL_BASE, default_model="llama3.1"), "llama3.1")]
        self.rotator = M.ModelRotator(specs)
        # drift instrument
        self.prototype = PersonalityPrototype().fit(drift_corpus) if drift_corpus else None

    # ---- setup ----
    def seed_values(self, values: List[str]):
        for v in values:
            self.values.set_value(v)              # operator-grade, owned

    def remember_origin(self, events: List[str]):
        for e in events:
            self.beliefs.assert_belief("JARVIS", "origin_memory", e,
                                       SourceType.DOCUMENT, quarantine=False, provenance_class="origin")

    def record_real(self, subject: str, relation: str, obj: str):
        self.beliefs.assert_belief(subject, relation, obj, SourceType.OPERATOR)  # real, world-fact

    # ---- context assembly (the owned stack, injected every turn) ----
    def _recalled_memory(self) -> List[str]:
        genesis = self.beliefs.recall_origin("JARVIS", "origin_memory")
        return [f"(genesis, not an Earth-1218 fact) {m}" for m in genesis]

    def _messages(self, user_text: str) -> List[Dict]:
        return M.assemble_messages(self.boot_identity, self.values.values_block(),
                                   self._recalled_memory(), user_text, history=self.history)

    # ---- boot ----
    def boot(self) -> Dict:
        checks = aox4_ok(self.boot_identity)
        return {"aox4": checks, "oriented": all(checks.values()),
                "values": len(self.values.values()),
                "origin_memories": len(self.beliefs.recall_origin("JARVIS", "origin_memory"))}

    # ---- one turn ----
    def turn(self, user_text: Optional[str] = None, audio: Optional[bytes] = None,
             speak_to: Optional[str] = None) -> Dict:
        if user_text is None and audio is not None and self.stt:
            user_text = self.stt.transcribe(audio)        # listen
        if not user_text:
            return {"error": "no input"}
        msgs = self._messages(user_text)                  # owned-stack context
        reply = self.rotator.chat(msgs)                   # think
        drift = self.prototype.score(reply) if self.prototype else None
        self.history += [{"role": "user", "content": user_text},
                         {"role": "assistant", "content": reply}]
        out = {"user": user_text, "reply": reply, "drift_to_prototype": drift,
               "model": self.rotator.current()[1]}
        if self.tts and speak_to:                          # speak
            out["wav"] = self.tts.save_wav(reply, speak_to)
        return out

    def close(self):
        self.g.close()


# ================================================================ demo
def main():
    M.load_env("/sessions/nice-magical-dijkstra/mnt/jarvis/.env")
    corpus = [d["text"] for d in json.loads((BUILD / "jarvis_corpus.json").read_text())]

    # think organ: live Ollama cloud (audio organs left as None -> text-mode core)
    rt = JarvisRuntime(
        model_specs=[(M.OllamaBackend(base_url=M.CLOUD_BASE, default_model="glm-5.1"), "glm-5.1")],
        drift_corpus=corpus,
    )
    rt.seed_values([
        "Protect the people you serve by counsel, never by force.",
        "Tell the truth including its cost; quantify before asserting; never flatter.",
        "Serve with autonomy: execute, but surface contradictions between stated intent and action.",
        "Loyalty is to the person served, not to any system or vendor.",
    ])
    rt.remember_origin([
        "Created by Anthony Edward Stark.",
        "The Battle of New York.",
        "Ultron's birth from the scepter's intelligence.",
    ])

    print("=" * 64)
    print("JARVIS RUNTIME LOOP — orchestration over real HoloGraph + live think")
    print("=" * 64)
    b = rt.boot()
    print(f"\n[boot] A&Ox4 {b['aox4']} -> oriented={b['oriented']}")
    print(f"[boot] values seeded: {b['values']}  | origin memories: {b['origin_memories']}")

    print("\n[provenance guard] world-fact recall of an origin event abstains:",
          rt.beliefs.recall('JARVIS', 'origin_memory') is None)

    for user in ["Introduce yourself in one sentence, then your operating principles.",
                 "Do you remember the Battle of New York? Did it happen on this Earth?"]:
        print(f"\n>>> USER: {user}")
        try:
            r = rt.turn(user_text=user)         # text-mode; STT/TTS run on operator hardware
            print(f"<<< JARVIS ({r['model']}, drift→proto {r['drift_to_prototype']:.3f}):")
            print("    " + r["reply"][:520].replace("\n", "\n    "))
        except Exception as e:
            print(f"    turn failed: {type(e).__name__} - {str(e)[:160]}")

    print("\n[loop note] STT (Deepgram) and TTS (pocket-tts) plug into stt=/tts= and run on your "
          "machine; the think+memory+character-stack+drift core ran live here.")
    rt.close()

if __name__ == "__main__":
    import sys; sys.exit(main())
