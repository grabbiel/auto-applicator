"""Async IMAP listener that finds verification codes (OTPs) and confirmation links sent by job portals."""

from __future__ import annotations

import asyncio
import email
import email.policy
import imaplib
import logging
import re
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from email.message import EmailMessage
from email.utils import parseaddr, parsedate_to_datetime
from typing import Literal

from bs4 import BeautifulSoup

from .config import Secrets
from .llm import LLMClient, LLMError

log = logging.getLogger(__name__)

Kind = Literal["code", "link", "any"]


@dataclass
class VerificationResult:
    code: str | None
    url: str | None
    subject: str
    sender: str
    received_at: datetime | None
    source: Literal["regex", "llm"]


@dataclass
class ParsedEmail:
    subject: str
    sender: str
    date: datetime | None
    text: str
    links: list[tuple[str, str]]  # (anchor text, href)

    def haystack(self) -> str:
        return f"{self.sender}\n{self.subject}\n{self.text}".lower()


# --------------------------------------------------------------------------- parsing


def parse_message(raw: bytes) -> ParsedEmail:
    msg: EmailMessage = email.message_from_bytes(raw, policy=email.policy.default)  # type: ignore[assignment]
    plain, html = [], []
    for part in msg.walk():
        if part.is_multipart() or part.get_content_disposition() == "attachment":
            continue
        ctype = part.get_content_type()
        try:
            content = part.get_content()
        except (LookupError, ValueError):
            payload = part.get_payload(decode=True) or b""
            content = payload.decode("utf-8", "replace")
        if ctype == "text/plain":
            plain.append(content)
        elif ctype == "text/html":
            html.append(content)
    links: list[tuple[str, str]] = []
    html_text = ""
    if html:
        soup = BeautifulSoup("\n".join(html), "lxml")
        for tag in soup(["script", "style", "head"]):
            tag.decompose()
        links = [(a.get_text(" ", strip=True), a["href"].strip()) for a in soup.find_all("a", href=True)]
        html_text = soup.get_text("\n", strip=True)
    text = "\n".join(plain) if plain else html_text
    if plain:
        links += [("", u) for u in re.findall(r"https?://[^\s<>\"')\]]+", text)]
    try:
        date = parsedate_to_datetime(msg.get("Date", "")) if msg.get("Date") else None
        if date and date.tzinfo is None:
            date = date.replace(tzinfo=UTC)
    except (TypeError, ValueError):
        date = None
    return ParsedEmail(
        subject=str(msg.get("Subject", "")),
        sender=parseaddr(str(msg.get("From", "")))[1] or str(msg.get("From", "")),
        date=date,
        text=text,
        links=links,
    )


# --------------------------------------------------------------------------- regex extractors

_CODE_KEYWORDS = re.compile(r"\b(security code|verification code|one[- ]time (pass)?code|passcode|otp|code)\b", re.I)
_CODE_AFTER_LABEL = r"(?:code|application|passcode|otp|pin)\s*(?:is|:|-)\s*\**\s*([A-Za-z0-9]{%d})\b"
_WORDLIKE = {"linkedin", "password", "security", "workday", "required", "position", "personal", "complete"}


def _looks_like_code(token: str) -> bool:
    if token.lower() in _WORDLIKE:
        return False
    has_digit = any(c.isdigit() for c in token)
    has_alpha = any(c.isalpha() for c in token)
    uppers = sum(c.isupper() for c in token[1:])
    return (has_digit and has_alpha) or (uppers >= 2 and any(c.islower() for c in token)) or token.isupper()


def extract_code(text: str, length: int | None = None) -> str | None:
    """Find an OTP. length=8 -> Greenhouse-style alphanumeric; length=6 / None -> numeric codes first."""
    lengths = [length] if length else [6, 8]
    lines = [ln.strip().strip("*").strip() for ln in text.splitlines()]
    for n in lengths:
        numeric_only = n == 6 and not length
        # 1) "code: XXXX" / "application: XXXX"
        for m in re.finditer(_CODE_AFTER_LABEL % n, text, re.I):
            tok = m.group(1)
            if (tok.isdigit() if numeric_only else (tok.isdigit() or _looks_like_code(tok))):
                return tok
        # 2) a line that is only the code (optionally "123 456"), close to a code keyword
        keyword_lines = [i for i, ln in enumerate(lines) if _CODE_KEYWORDS.search(ln)]
        for i, ln in enumerate(lines):
            compact = ln.replace(" ", "") if re.fullmatch(r"\d{3} \d{3}", ln) else ln
            if len(compact) != n or not compact.isalnum():
                continue
            if numeric_only and not compact.isdigit():
                continue
            if not compact.isdigit() and not _looks_like_code(compact):
                continue
            if any(abs(i - k) <= 4 for k in keyword_lines):
                return compact
        # 3) digits right after a keyword
        if n == 6:
            m = re.search(r"(?:code|otp|passcode|pin)\D{0,40}?(?<!\d)(\d{6})(?!\d)", text, re.I)
            if m:
                return m.group(1)
        # 4) alphanumeric token in a sentence that mentions a code
        if not numeric_only:
            for m in _CODE_KEYWORDS.finditer(text):
                window = text[m.start() : m.end() + 160]
                for tok in re.findall(rf"(?<![A-Za-z0-9])([A-Za-z0-9]{{{n}}})(?![A-Za-z0-9])", window):
                    if _looks_like_code(tok):
                        return tok
    return None


_LINK_GOOD = re.compile(r"verif|confirm|activat|validat|magic|sign[-_ ]?in|login|token=|email_verification", re.I)
_LINK_BAD = re.compile(r"unsubscribe|privacy|terms|preferences|help|support|facebook|twitter|linkedin\.com/company|mailto:", re.I)


def extract_link(links: list[tuple[str, str]], domain_hint: str = "") -> str | None:
    best: tuple[int, str] | None = None
    for text, href in links:
        if not href.lower().startswith("http") or _LINK_BAD.search(href):
            continue
        score = 0
        if _LINK_GOOD.search(href):
            score += 2
        if _LINK_GOOD.search(text):
            score += 3
        if domain_hint and domain_hint.lower() in href.lower():
            score += 2
        if "myworkday" in href.lower() or "workday" in href.lower():
            score += 1
        if score >= 3 and (best is None or score > best[0]):
            best = (score, href)
    return best[1] if best else None


def extract_from_email(parsed: ParsedEmail, kind: Kind = "any", code_length: int | None = None,
                       domain_hint: str = "") -> tuple[str | None, str | None]:
    code = extract_code(f"{parsed.subject}\n{parsed.text}", code_length) if kind in ("code", "any") else None
    url = extract_link(parsed.links, domain_hint) if kind in ("link", "any") else None
    return code, url


# --------------------------------------------------------------------------- IMAP listener


def _matches_hint(parsed: ParsedEmail, hint: str) -> bool:
    if not hint:
        return True
    hay = parsed.haystack()
    return any(h.strip().lower() in hay for h in hint.split("|") if h.strip())


class EmailVerifier:
    def __init__(
        self,
        secrets: Secrets,
        llm: LLMClient | None = None,
        *,
        poll_interval: float = 4.0,
        imap_factory: Callable[[str, int], imaplib.IMAP4] = imaplib.IMAP4_SSL,
    ):
        self.secrets = secrets
        self.llm = llm
        self.poll_interval = poll_interval
        self.imap_factory = imap_factory

    @property
    def configured(self) -> bool:
        return self.secrets.imap_configured

    def _connect(self) -> imaplib.IMAP4:
        conn = self.imap_factory(self.secrets.imap_host, self.secrets.imap_port)
        conn.login(self.secrets.imap_user, self.secrets.imap_app_password.get_secret_value())
        conn.select("INBOX")
        return conn

    @staticmethod
    def _search_unseen(conn: imaplib.IMAP4, since: datetime) -> list[bytes]:
        conn.noop()
        day = (since - timedelta(days=1)).strftime("%d-%b-%Y")
        typ, data = conn.uid("SEARCH", None, "UNSEEN", "SINCE", day)  # type: ignore[arg-type]
        if typ != "OK" or not data or not data[0]:
            return []
        return list(reversed(data[0].split()))  # newest first

    @staticmethod
    def _fetch(conn: imaplib.IMAP4, uid: bytes) -> bytes | None:
        typ, data = conn.uid("FETCH", uid, "(BODY.PEEK[])")  # PEEK: don't mark as read yet
        if typ != "OK":
            return None
        for item in data or []:
            if isinstance(item, tuple) and len(item) >= 2:
                return item[1]
        return None

    async def test_connection(self) -> int:
        """Log in and return the number of unread messages in INBOX."""

        def run() -> int:
            conn = self._connect()
            try:
                typ, data = conn.uid("SEARCH", None, "UNSEEN")  # type: ignore[arg-type]
                return len(data[0].split()) if typ == "OK" and data and data[0] else 0
            finally:
                conn.logout()

        return await asyncio.to_thread(run)

    async def recent_messages(self, limit: int = 15) -> list[ParsedEmail]:
        def run() -> list[ParsedEmail]:
            conn = self._connect()
            try:
                typ, data = conn.uid("SEARCH", None, "ALL")  # type: ignore[arg-type]
                uids = data[0].split()[-limit:] if typ == "OK" and data and data[0] else []
                out = []
                for uid in reversed(uids):
                    raw = self._fetch(conn, uid)
                    if raw:
                        out.append(parse_message(raw))
                return out
            finally:
                conn.logout()

        return await asyncio.to_thread(run)

    async def wait_for_verification(
        self,
        sender_hint: str,
        since_timestamp: datetime,
        timeout_sec: int = 60,
        *,
        kind: Kind = "any",
        code_length: int | None = None,
    ) -> VerificationResult | None:
        """Poll INBOX for an UNSEEN message newer than since_timestamp that contains a code/link."""
        if not self.configured:
            log.warning("IMAP is not configured; cannot read verification emails.")
            return None
        if since_timestamp.tzinfo is None:
            since_timestamp = since_timestamp.astimezone(UTC)
        conn = await asyncio.to_thread(self._connect)
        examined: set[bytes] = set()
        deadline = time.monotonic() + timeout_sec
        try:
            while time.monotonic() < deadline:
                uids = await asyncio.to_thread(self._search_unseen, conn, since_timestamp)
                for uid in uids:
                    if uid in examined:
                        continue
                    examined.add(uid)
                    raw = await asyncio.to_thread(self._fetch, conn, uid)
                    if not raw:
                        continue
                    parsed = parse_message(raw)
                    if parsed.date and parsed.date < since_timestamp - timedelta(minutes=2):
                        continue
                    if not _matches_hint(parsed, sender_hint):
                        continue
                    result = await self._extract(parsed, kind, code_length, sender_hint.split("|")[0])
                    if result:
                        await asyncio.to_thread(conn.uid, "STORE", uid, "+FLAGS", "(\\Seen)")
                        log.info("Verification email found: %r from %s", parsed.subject, parsed.sender)
                        return result
                await asyncio.sleep(self.poll_interval)
            return None
        finally:
            try:
                await asyncio.to_thread(conn.logout)
            except (imaplib.IMAP4.error, OSError):
                pass

    async def _extract(
        self, parsed: ParsedEmail, kind: Kind, code_length: int | None, domain_hint: str
    ) -> VerificationResult | None:
        code, url = extract_from_email(parsed, kind, code_length, domain_hint)
        if (kind == "code" and code) or (kind == "link" and url) or (kind == "any" and (code or url)):
            return VerificationResult(code, url, parsed.subject, parsed.sender, parsed.date, "regex")
        if not self.llm:
            return None
        body = parsed.text[:5000] + "\n\nLinks:\n" + "\n".join(f"{t} <{h}>" for t, h in parsed.links[:40])
        try:
            res = await self.llm.extract_verification(f"Subject: {parsed.subject}\nFrom: {parsed.sender}\n\n{body}")
        except LLMError as e:
            log.warning("LLM email extraction failed: %s", e)
            return None
        code = res.code.strip() if res.code and re.fullmatch(r"[A-Za-z0-9]{4,10}", res.code.strip()) else None
        if code and code_length and len(code) != code_length:
            code = None
        url = res.verification_url if res.verification_url and res.verification_url.startswith("http") else None
        if url and not any(url == h for _, h in parsed.links):
            url = None  # never trust a URL the model made up
        if (kind == "code" and code) or (kind == "link" and url) or (kind == "any" and (code or url)):
            return VerificationResult(code, url, parsed.subject, parsed.sender, parsed.date, "llm")
        return None
