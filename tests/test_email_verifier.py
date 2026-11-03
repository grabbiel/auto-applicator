from __future__ import annotations

from datetime import UTC, datetime, timedelta
from email.message import EmailMessage
from email.utils import format_datetime

from src.config import Secrets
from src.email_verifier import EmailVerifier, extract_code, extract_link, parse_message


def make_email(sender: str, subject: str, text: str | None = None, html: str | None = None,
               when: datetime | None = None) -> bytes:
    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = "jane.doe@example.com"
    msg["Subject"] = subject
    msg["Date"] = format_datetime(when or datetime.now(UTC))
    if text:
        msg.set_content(text)
    if html:
        if text:
            msg.add_alternative(html, subtype="html")
        else:
            msg.set_content(html, subtype="html")
    return msg.as_bytes()


GREENHOUSE = make_email(
    "Greenhouse <no-reply@us.greenhouse-mail.io>",
    "Security code for your application to Initech",
    text=(
        "Hi Jane,\n\nCopy and paste this code into the security code field on your application: nE5Cx0Ky\n\n"
        "After you enter the code, resubmit your application.\n"
    ),
)
SIX_DIGIT = make_email("Ashby <no-reply@ashbyhq.com>", "Your code", text="Your verification code is 482913. It expires in 10 minutes.")
SIX_DIGIT_LINE = make_email(
    "Lever <no-reply@hire.lever.co>", "Confirm",
    html="<p>Use the following one-time passcode</p><p><b>731 004</b></p><p>Call us at 800-555-1234</p>",
)
WORKDAY = make_email(
    "Initech Careers <initech@myworkday.com>",
    "Please verify your candidate account",
    html=(
        '<p>Welcome!</p><a href="https://initech.wd5.myworkdayjobs.com/en-US/careers/activate/abc123?token=z">'
        'Verify Account</a> <a href="https://initech.com/unsubscribe">Unsubscribe</a>'
        '<a href="https://initech.com/privacy">Privacy</a>'
    ),
)


def test_parse_and_extract_greenhouse_code():
    parsed = parse_message(GREENHOUSE)
    assert parsed.sender == "no-reply@us.greenhouse-mail.io"
    assert extract_code(parsed.text, 8) == "nE5Cx0Ky"


def test_extract_six_digit_codes():
    assert extract_code(parse_message(SIX_DIGIT).text) == "482913"
    assert extract_code(parse_message(SIX_DIGIT_LINE).text) == "731004"


def test_no_false_positive_codes():
    text = "Thanks for applying to LinkedIn's Security Engineer role. Your password manager is Complete."
    assert extract_code(text, 8) is None
    assert extract_code("Call 800-555-1234 or visit room 123456 tomorrow") is None


def test_extract_workday_link():
    parsed = parse_message(WORKDAY)
    assert extract_link(parsed.links, "myworkday") == "https://initech.wd5.myworkdayjobs.com/en-US/careers/activate/abc123?token=z"
    assert extract_link([("Unsubscribe", "https://x.com/unsubscribe"), ("Home", "https://x.com")]) is None


class FakeIMAP:
    """Minimal imaplib.IMAP4 stand-in holding a list of (uid, raw_bytes, seen)."""

    def __init__(self, messages):
        self.messages = {str(i + 1).encode(): [raw, False] for i, raw in enumerate(messages)}
        self.logged_in = False

    def login(self, user, pw):
        self.logged_in = True

    def select(self, box):
        return "OK", [b"1"]

    def noop(self):
        return "OK", []

    def logout(self):
        return "BYE", []

    def uid(self, cmd, *args):
        if cmd == "SEARCH":
            unseen = "UNSEEN" in args
            uids = [u for u, (_, seen) in self.messages.items() if not (unseen and seen)]
            return "OK", [b" ".join(uids)]
        if cmd == "FETCH":
            uid = args[0]
            return "OK", [(b"1 (BODY[] {n}", self.messages[uid][0]), b")"]
        if cmd == "STORE":
            self.messages[args[0]][1] = True
            return "OK", []
        raise AssertionError(cmd)


def configured_secrets() -> Secrets:
    return Secrets(imap_user="jane.doe@example.com", imap_app_password="abcdabcdabcdabcd")  # type: ignore[arg-type]


async def test_wait_for_verification_filters_by_time_and_sender():
    since = datetime.now(UTC)
    old = make_email("no-reply@greenhouse-mail.io", "Old code", text="security code field on your application: OLD1code",
                     when=since - timedelta(hours=1))
    other = make_email("news@shop.com", "Sale", text="Use code: SAVE2024 today")
    imap = FakeIMAP([old, other, GREENHOUSE])
    verifier = EmailVerifier(configured_secrets(), imap_factory=lambda h, p: imap, poll_interval=0.01)
    res = await verifier.wait_for_verification("greenhouse", since, timeout_sec=2, kind="code", code_length=8)
    assert res is not None and res.code == "nE5Cx0Ky" and res.source == "regex"
    assert imap.messages[b"3"][1] is True  # marked as read once used
    assert imap.messages[b"2"][1] is False


async def test_wait_for_verification_times_out():
    imap = FakeIMAP([make_email("news@shop.com", "Hi", text="nothing here")])
    verifier = EmailVerifier(configured_secrets(), imap_factory=lambda h, p: imap, poll_interval=0.01)
    res = await verifier.wait_for_verification("workday", datetime.now(UTC), timeout_sec=0.2, kind="link")
    assert res is None


async def test_unconfigured_imap_returns_none():
    verifier = EmailVerifier(Secrets(), imap_factory=lambda h, p: None)  # type: ignore[arg-type]
    assert await verifier.wait_for_verification("x", datetime.now(UTC), timeout_sec=1) is None
