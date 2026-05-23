#!/usr/bin/env python3
"""Paper-reading sessions for dyslexia-friendly, interruptible review.

The important invariant: reading state and discussion state are the same session. If the
operator says "hold up", the cursor stays on the current sentence/paragraph while JARVIS
answers questions, marks notes, or resumes.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import Optional, Any


@dataclass
class PaperUnit:
    page: int
    paragraph: int
    sentence: int
    text: str

    def ref(self) -> str:
        return f"p{self.page}:para{self.paragraph}:s{self.sentence}"

    def as_dict(self) -> dict:
        return {"ref": self.ref(), "page": self.page, "paragraph": self.paragraph,
                "sentence": self.sentence, "text": self.text}


class PaperSession:
    def __init__(self):
        self.path: Optional[str] = None
        self.title: Optional[str] = None
        self.units: list[PaperUnit] = []
        self.index = 0
        self.paused = True
        self.marks: list[dict] = []
        self.discussion: list[dict] = []
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._process: Optional[subprocess.Popen] = None

    # ---- loading / segmentation ----
    def load(self, path: str, title: Optional[str] = None, start: int = 0) -> dict:
        p = pathlib.Path(path).expanduser()
        if not p.exists():
            raise FileNotFoundError(str(p))
        text_pages = self._extract_pages(p)
        units = self._segment_pages(text_pages)
        if not units:
            raise ValueError("paper text extraction produced no readable text")

        self.pause()
        with self._lock:
            self.path = str(p)
            self.title = title or p.stem
            self.units = units
            self.index = max(0, min(int(start), len(units) - 1))
            self.paused = True
            self.marks = []
            self.discussion = []
            return self.status()

    def _extract_pages(self, path: pathlib.Path) -> list[tuple[int, str]]:
        if path.suffix.lower() == ".pdf":
            try:
                from pypdf import PdfReader
            except ImportError as exc:
                raise RuntimeError("pypdf is required for PDF paper loading") from exc
            reader = PdfReader(str(path))
            return [(i + 1, page.extract_text() or "") for i, page in enumerate(reader.pages)]
        return [(1, path.read_text(errors="replace"))]

    def _segment_pages(self, pages: list[tuple[int, str]]) -> list[PaperUnit]:
        units: list[PaperUnit] = []
        for page_no, text in pages:
            text = re.sub(r"[ \t]+", " ", text.replace("\r", "\n")).strip()
            if not text:
                continue
            paragraphs = [p.strip() for p in re.split(r"\n\s*\n+", text) if p.strip()]
            if len(paragraphs) <= 1:
                paragraphs = [p.strip() for p in text.split("\n") if p.strip()]
            for para_no, paragraph in enumerate(paragraphs, start=1):
                for sent_no, sentence in enumerate(self._split_sentences(paragraph), start=1):
                    units.append(PaperUnit(page_no, para_no, sent_no, sentence))
        return units

    def _split_sentences(self, paragraph: str) -> list[str]:
        paragraph = re.sub(r"\s+", " ", paragraph).strip()
        if not paragraph:
            return []
        pieces = re.split(r"(?<=[.!?])\s+(?=[A-Z0-9\"'([])", paragraph)
        out: list[str] = []
        buf = ""
        for piece in pieces:
            candidate = (buf + " " + piece).strip() if buf else piece.strip()
            if len(candidate) < 45 and not candidate.endswith((".", "!", "?")):
                buf = candidate
                continue
            out.append(candidate)
            buf = ""
        if buf:
            out.append(buf)
        return out

    # ---- cursor / context ----
    def loaded(self) -> bool:
        return bool(self.units)

    def _current_locked(self) -> PaperUnit:
        if not self.units:
            raise RuntimeError("no paper loaded")
        self.index = max(0, min(self.index, len(self.units) - 1))
        return self.units[self.index]

    def status(self) -> dict:
        with self._lock:
            current = self._current_locked().as_dict() if self.units else None
            return {
                "loaded": bool(self.units),
                "path": self.path,
                "title": self.title,
                "index": self.index,
                "total_units": len(self.units),
                "paused": self.paused,
                "speaking": bool(self._process and self._process.poll() is None),
                "current": current,
                "marks": len(self.marks),
                "discussion_turns": len(self.discussion),
            }

    def current(self, count: int = 1) -> dict:
        with self._lock:
            return {"cursor": self.status(), "units": [u.as_dict() for u in self._slice_from(self.index, count)]}

    def next(self, count: int = 1) -> dict:
        with self._lock:
            self.index = min(len(self.units) - 1, self.index + max(1, int(count)))
            return self.current()

    def back(self, count: int = 1) -> dict:
        with self._lock:
            self.index = max(0, self.index - max(1, int(count)))
            return self.current()

    def _slice_from(self, start: int, count: int) -> list[PaperUnit]:
        if not self.units:
            raise RuntimeError("no paper loaded")
        count = max(1, int(count))
        return self.units[start:min(len(self.units), start + count)]

    def context(self, window: int = 5) -> dict:
        with self._lock:
            current = self._current_locked()
            radius = max(1, int(window))
            start = max(0, self.index - radius)
            end = min(len(self.units), self.index + radius + 1)
            return {
                "title": self.title,
                "path": self.path,
                "cursor": self.index,
                "current": current.as_dict(),
                "nearby": [u.as_dict() for u in self.units[start:end]],
                "marks": list(self.marks[-10:]),
            }

    def mark(self, note: str = "") -> dict:
        with self._lock:
            unit = self._current_locked()
            entry = {"t": time.time(), "cursor": self.index, "unit": unit.as_dict(), "note": note}
            self.marks.append(entry)
            return entry

    def remember_discussion(self, question: str, answer: str) -> None:
        with self._lock:
            self.discussion.append({"t": time.time(), "cursor": self.index,
                                    "question": question, "answer": answer})

    # ---- speaking ----
    def read_aloud(self, count: int = 12, voice: Optional[str] = None, rate: Optional[int] = None) -> dict:
        if not self.units:
            raise RuntimeError("no paper loaded")
        self.pause()
        with self._lock:
            self.paused = False
            self._stop.clear()
            self._thread = threading.Thread(target=self._speak_loop,
                                            args=(max(1, int(count)), voice, rate),
                                            daemon=True)
            self._thread.start()
            return self.status()

    def resume(self, count: int = 12, voice: Optional[str] = None, rate: Optional[int] = None) -> dict:
        return self.read_aloud(count=count, voice=voice, rate=rate)

    def pause(self) -> dict:
        self._stop.set()
        with self._lock:
            self.paused = True
            proc = self._process
            if proc and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=1.5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=1.5)
            self._process = None
            return self.status() if self.units else {"loaded": False, "paused": True}

    def _speak_loop(self, count: int, voice: Optional[str], rate: Optional[int]) -> None:
        spoken = 0
        while not self._stop.is_set() and spoken < count:
            with self._lock:
                if self.index >= len(self.units):
                    self.paused = True
                    return
                unit = self.units[self.index]
                argv = ["say"]
                if voice:
                    argv += ["-v", str(voice)]
                if rate:
                    argv += ["-r", str(int(rate))]
                argv.append(unit.text)
                self._process = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                proc = self._process
            while proc.poll() is None and not self._stop.is_set():
                time.sleep(0.05)
            if self._stop.is_set():
                if proc.poll() is None:
                    proc.terminate()
                break
            with self._lock:
                if proc.returncode == 0:
                    self.index = min(len(self.units) - 1, self.index + 1)
                    spoken += 1
                self._process = None
        with self._lock:
            self.paused = True


if __name__ == "__main__":
    import tempfile
    p = pathlib.Path(tempfile.gettempdir()) / "paper_session_test.txt"
    p.write_text("First sentence. Second sentence.\n\nAnother paragraph asks a question? Final answer.")
    ps = PaperSession()
    loaded = ps.load(str(p))
    assert loaded["loaded"] and loaded["total_units"] == 4
    assert ps.current()["units"][0]["text"] == "First sentence."
    ps.next(); assert "Second" in ps.current()["units"][0]["text"]
    ps.back(); assert "First" in ps.current()["units"][0]["text"]
    mark = ps.mark("important")
    assert mark["note"] == "important" and mark["unit"]["ref"].startswith("p1:")
    assert ps.context()["current"]["text"] == "First sentence."
    p.unlink()
    print("PAPER SESSION SELF-TEST: PASS")
