"""Search layer for the misteramazing `_quotes` card collection.

Small corpus (tens of cards), so no index is built: records are held in
memory and scored lexically, with an optional one-shot Gemini expansion of
the query into related terms. The corpus itself is never sent to a model —
same principle as the greatBooks query layer.

Every quote may exist in several card *styles*. Styles are discovered from
whatever is on disk, in any of these layouts:

    cards/<qid>.jpg              -> style "default"
    cards/<style>/<qid>.jpg      -> style "<style>"
    cards/<qid>__<style>.jpg     -> style "<style>"

so the seven card designs in tools/card_template.py light up automatically
once they are shot, without a server change.
"""
from __future__ import annotations

import json
import logging
import os
import random
import re
from pathlib import Path

log = logging.getLogger("myquotes")

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}

STOPWORDS = {
    "the", "a", "an", "and", "or", "but", "of", "in", "on", "at", "to", "for",
    "with", "from", "by", "as", "is", "are", "was", "were", "be", "been", "it",
    "its", "this", "that", "these", "those", "about", "into", "over", "what",
    "which", "who", "whom", "how", "why", "when", "where", "all", "any", "some",
    "quotes", "quote", "quotation", "quotations", "card", "cards", "something",
    "anything", "me", "my", "i", "you", "we", "they",
}


def _norm(text: str) -> str:
    return re.sub(r"[^\w\s]", " ", (text or "").lower())


def _stem(token: str) -> str:
    """Crude suffix strip so 'difference' and 'differences' meet."""
    for suffix in ("ations", "ation", "ings", "ing", "ness", "ies", "ers", "er",
                   "es", "s"):
        if len(token) > len(suffix) + 3 and token.endswith(suffix):
            return token[: -len(suffix)]
    return token


def _tokens(text: str) -> list[str]:
    return [_stem(t) for t in _norm(text).split()
            if len(t) > 2 and t not in STOPWORDS]


class MyQuotes:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.cards_dir = root / "cards"
        self.records: list[dict] = []
        self.styles: dict[str, list[tuple[str, Path]]] = {}
        self._expansions: dict[str, list[str]] = {}
        self.load()

    # ── loading ──────────────────────────────────────────────────────────

    def load(self) -> None:
        meta_path = self.root / "data" / "metadata.json"
        raw = json.loads(meta_path.read_text(encoding="utf-8"))
        records = raw if isinstance(raw, list) else list(raw.values())
        self.records = []
        for r in records:
            qid = r.get("qid")
            if not qid:
                continue
            text = " ".join((r.get("text") or "").split())
            record = {
                "qid": qid,
                "text": text,
                "gloss": " ".join((r.get("gloss") or "").split()),
                "work": r.get("work") or "",
                "section": r.get("section") or "",
                "sectionName": r.get("section_name") or r.get("section") or "",
                "shortlink": r.get("shortlink") or "",
                "colour": r.get("colour") or "",
                "slug": r.get("slug") or "",
            }
            record["_tokens"] = set(_tokens(text)) | set(_tokens(record["gloss"]))
            record["_meta_tokens"] = set(_tokens(record["work"])) | set(
                _tokens(record["sectionName"]))
            record["_text_norm"] = _norm(text)
            self.records.append(record)
        self.styles = self._scan_styles()
        counts = {qid: len(v) for qid, v in self.styles.items()}
        most = max(counts.values()) if counts else 0
        log.info("my-quotes: %d cards, %d with artwork, up to %d style(s) each",
                 len(self.records), len(self.styles), most)

    def _scan_styles(self) -> dict[str, list[tuple[str, Path]]]:
        found: dict[str, dict[str, Path]] = {}
        if not self.cards_dir.is_dir():
            return {}
        known = {r["qid"] for r in self.records}

        def offer(qid: str, style: str, path: Path) -> None:
            if qid in known:
                found.setdefault(qid, {}).setdefault(style, path)

        for entry in self.cards_dir.iterdir():
            if entry.is_dir():
                # cards/<style>/<qid>.jpg
                for card in entry.iterdir():
                    if card.suffix.lower() in IMAGE_EXTS:
                        offer(card.stem, entry.name, card)
            elif entry.suffix.lower() in IMAGE_EXTS:
                stem = entry.stem
                if "__" in stem:
                    qid, _, style = stem.partition("__")
                    offer(qid, style or "default", entry)
                else:
                    offer(stem, "default", entry)

        return {qid: sorted(styles.items()) for qid, styles in found.items()}

    # ── search ───────────────────────────────────────────────────────────

    def search(self, query: str, section: str = "", limit: int = 60) -> list[dict]:
        pool = [r for r in self.records
                if not section or r["section"] == section]
        query = (query or "").strip()
        if not query:
            rows = sorted(pool, key=lambda r: (r["section"], r["qid"]))
            return [self._present(r) for r in rows[:limit]]

        terms = _tokens(query)
        expanded = [t for t in self._expand(query) if t not in terms]
        phrase = _norm(query).strip()
        scored: list[tuple[float, dict]] = []
        for record in pool:
            score = self._score(record, terms, expanded, phrase)
            if score > 0:
                scored.append((score, record))
        scored.sort(key=lambda pair: (-pair[0], pair[1]["qid"]))
        return [self._present(r) for _, r in scored[:limit]]

    def _score(self, record: dict, terms: list[str], expanded: list[str],
               phrase: str) -> float:
        score = 0.0
        if phrase and len(phrase) > 4 and phrase in record["_text_norm"]:
            score += 10
        for term in terms:
            if term in record["_tokens"]:
                score += 3
            elif any(t.startswith(term) or term.startswith(t)
                     for t in record["_tokens"]):
                score += 1.5
            if term in record["_meta_tokens"]:
                score += 2
        for term in expanded:
            if term in record["_tokens"]:
                score += 1.2
            if term in record["_meta_tokens"]:
                score += 0.8
        return score

    def _expand(self, query: str) -> list[str]:
        """One tiny Gemini call turning a question into related terms.

        Only the query travels — never the corpus. Memoized per process, and
        silently skipped without a key or on any failure.
        """
        key = os.environ.get("GEMINI_API_KEY")
        if not key:
            return []
        cached = self._expansions.get(query)
        if cached is not None:
            return cached
        terms: list[str] = []
        try:
            from google import genai

            client = genai.Client(api_key=key)
            response = client.models.generate_content(
                model="gemini-flash-latest",
                contents=(
                    "List up to 8 single words closely related to this search, "
                    "as a JSON array of lowercase strings and nothing else. "
                    f"Search: {query}"),
            )
            body = (response.text or "").strip()
            body = re.sub(r"^```(?:json)?|```$", "", body, flags=re.MULTILINE).strip()
            parsed = json.loads(body)
            if isinstance(parsed, list):
                terms = [_stem(str(t).lower()) for t in parsed
                         if isinstance(t, (str, int))][:8]
        except Exception as e:
            log.debug("my-quotes expansion skipped: %s", e)
            terms = []
        self._expansions[query] = terms
        return terms

    # ── presentation ─────────────────────────────────────────────────────

    def _present(self, record: dict) -> dict:
        styles = [name for name, _ in self.styles.get(record["qid"], [])]
        return {
            "qid": record["qid"],
            "text": record["text"],
            "gloss": record["gloss"],
            "work": record["work"],
            "section": record["section"],
            "sectionName": record["sectionName"],
            "colour": record["colour"],
            "shortlink": record["shortlink"],
            "styles": styles,
        }

    def randomize_styles(self, rows: list[dict], rng: random.Random) -> list[dict]:
        """Pick a style per row. A fresh RNG per request is what makes every
        search shuffle differently."""
        for row in rows:
            styles = row.get("styles") or []
            row["style"] = rng.choice(styles) if styles else ""
        return rows

    def sections(self) -> list[dict]:
        counts: dict[str, tuple[str, int]] = {}
        for record in self.records:
            name, count = counts.get(record["section"], (record["sectionName"], 0))
            counts[record["section"]] = (name, count + 1)
        return [{"slug": slug, "name": name, "count": count}
                for slug, (name, count) in sorted(counts.items())]

    def card_path(self, qid: str, style: str = "") -> Path | None:
        entries = self.styles.get(qid)
        if not entries:
            return None
        if style:
            for name, path in entries:
                if name == style:
                    return path
        return entries[0][1]
