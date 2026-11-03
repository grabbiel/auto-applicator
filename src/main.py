"""Command-line entry point (the macOS app runs these commands too, and --app-backend for its setup screens)."""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from datetime import datetime

from rich.console import Console
from rich.logging import RichHandler
from rich.panel import Panel
from rich.prompt import Confirm, Prompt
from rich.table import Table

from . import __version__, macos, schedule
from .answers import coerce_answer
from .browser import BrowserError, BrowserManager
from .config import ConfigError, Paths, Settings, load_settings
from .db import Database
from .email_verifier import EmailVerifier, extract_from_email
from .llm import FieldSpec, LLMClient, LLMError
from .pipeline import Pipeline, PipelineError, notify_summary

console = Console()
log = logging.getLogger("auto_applicator")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="auto-applicator", description="Local job-application assistant.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--app-backend", action="store_true", help=argparse.SUPPRESS)  # Auto Applicator.app talks to this
    g.add_argument("--setup", action="store_true", help="terminal setup wizard: profile (with resume import), job search, email")
    g.add_argument("--login", action="store_true", help="open the browser to log in to LinkedIn once")
    g.add_argument("--dry-run", action="store_true", help="fill applications but never click the final Submit")
    g.add_argument("--run", action="store_true", help="run the pipeline honouring dry_run in config.yaml (used by the schedule)")
    g.add_argument("--live", action="store_true", help="submit real applications now (asks for confirmation)")
    g.add_argument("--test-imap", action="store_true", help="check the email (IMAP) connection and code/link parsing")
    g.add_argument("--answer-pending", action="store_true", help="answer the questions that caused jobs to be skipped")
    g.add_argument("--status", action="store_true", help="show recent results")
    g.add_argument("--doctor", action="store_true", help="check that everything is installed and configured")
    g.add_argument("--open-settings", action="store_true", help="open the settings folder in Finder")
    g.add_argument("--install-schedule", action="store_true", help="run automatically at the time set in config.yaml")
    g.add_argument("--uninstall-schedule", action="store_true", help="remove the automatic schedule")
    p.add_argument("--yes", action="store_true", help="don't ask for confirmation (with --live)")
    p.add_argument("--no-input", action="store_true", help="with --login: wait for the sign-in instead of asking for Enter")
    p.add_argument("--verbose", action="store_true", help="more detailed console logging")
    p.add_argument("--version", action="version", version=f"auto-applicator {__version__}")
    return p


def setup_logging(paths: Paths, verbose: bool) -> None:
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    for h in list(root.handlers):
        root.removeHandler(h)
    ch = RichHandler(console=console, show_path=False, show_time=False, level=logging.DEBUG if verbose else logging.WARNING)
    fh = logging.FileHandler(paths.logs_dir / f"auto-applicator-{datetime.now():%Y%m%d}.log", encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root.addHandler(ch)
    root.addHandler(fh)
    for noisy in ("httpx", "httpcore", "openai", "asyncio"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


# --------------------------------------------------------------------------- commands


async def cmd_login(settings: Settings, wait_for_enter: bool = True) -> int:
    async with BrowserManager(settings.paths, settings.config.browser) as bm:
        page = await bm.main_page()
        await page.goto("https://www.linkedin.com/login")
        if not wait_for_enter:
            return await _wait_for_sign_in(bm)
        console.print(Panel(
            "A browser window opened on the LinkedIn sign-in page.\n\n"
            "1. Sign in (and finish any verification LinkedIn asks for).\n"
            "2. Wait until you see your LinkedIn feed.\n"
            "3. Come back to this window and press [bold]Enter[/].\n\n"
            "You only need to do this once: the session is kept in your settings folder.",
            title="Log in to LinkedIn", border_style="cyan",
        ))
        await asyncio.to_thread(input, "Press Enter when you're logged in… ")
        if await bm.is_logged_in(page):
            console.print("[bold green]✓ Logged in. You're ready to do a dry run.[/]")
            return 0
        console.print("[red]✗ Still not logged in. Please try again.[/]")
        return 1


async def _wait_for_sign_in(bm: BrowserManager, timeout_sec: float = 15 * 60) -> int:
    """Used by the app: bring the browser to the front and wait until LinkedIn has a session."""
    from playwright.async_api import Error as PlaywrightError

    macos.activate_app(macos.app_bundle_for(bm.executable_path or ""))
    console.print("Waiting for you to sign in to LinkedIn in the browser window…")
    deadline = asyncio.get_running_loop().time() + timeout_sec
    try:
        while asyncio.get_running_loop().time() < deadline:
            if not bm.context or not bm.context.pages:
                console.print("The browser window was closed.")
                return 1
            if await bm.has_session_cookie():
                await asyncio.sleep(2)  # let LinkedIn finish its post-login redirects
                if await bm.is_logged_in(bm.context.pages[0]):
                    console.print("✓ Logged in.")
                    await asyncio.sleep(1.5)
                    return 0
            await asyncio.sleep(2)
    except PlaywrightError as e:
        console.print(f"The browser closed ({e.__class__.__name__}).")
        return 1
    console.print("Timed out waiting for the sign-in.")
    return 1


async def cmd_pipeline(settings: Settings, dry_run: bool) -> int:
    mode = "[cyan]DRY RUN[/] (nothing will be submitted)" if dry_run else "[bold red]LIVE[/] (applications will be submitted)"
    console.print(Panel(
        f"Mode: {mode}\nSearches: {len(settings.config.search_queries)} · max applications: "
        f"{settings.config.limits.max_applies_per_run}\nScreenshots: {settings.paths.screenshots_dir}",
        title="Auto Applicator", border_style="cyan" if dry_run else "red",
    ))
    pipeline = Pipeline(settings, dry_run=dry_run, console=console)
    try:
        summary = await pipeline.run()
    finally:
        if pipeline.summary.rows:
            console.print(pipeline.summary.table())
    notify_summary(summary, dry_run)
    if summary.counts.get("SKIPPED_NEEDS_ANSWER"):
        console.print("[yellow]Some jobs need your answers. Answer them once under 'Questions' in the app (or ./aa --answer-pending).[/]")
    return 0


async def cmd_test_imap(settings: Settings) -> int:
    s = settings.secrets
    if not s.imap_configured:
        console.print("[yellow]Email is not set up yet. Run setup and choose the email step.[/]")
        return 2
    verifier = EmailVerifier(s)
    with console.status(f"Connecting to {s.imap_host} as {s.imap_user}…"):
        try:
            unread = await verifier.test_connection()
        except Exception as e:  # noqa: BLE001 – imaplib raises several unrelated types
            console.print(f"[red]✗ Could not log in: {e}[/]\nFor Gmail, use an App Password, not your normal password.")
            return 1
    console.print(f"[green]✓ Connected.[/] {unread} unread message(s) in INBOX.")
    with console.status("Scanning your 10 most recent emails for codes/links (read-only)…"):
        messages = await verifier.recent_messages(10)
    table = Table(title="Recent emails (nothing is marked as read)")
    for col in ("Date", "From", "Subject", "Code", "Verification link"):
        table.add_column(col, overflow="fold")
    for m in messages:
        code, url = extract_from_email(m)
        table.add_row(f"{m.date:%Y-%m-%d %H:%M}" if m.date else "", m.sender[:30], m.subject[:50], code or "", (url or "")[:60])
    console.print(table)
    return 0


def cmd_answer_pending(settings: Settings) -> int:
    db = Database(settings.paths.db_file)
    try:
        pending = db.list_pending()
        if not pending:
            console.print("[green]No questions are waiting for you.[/]")
            return 0
        console.print(Panel(
            f"{len(pending)} question(s) couldn't be answered from your profile.\n"
            "Each answer is saved and reused automatically on future applications, and the skipped jobs are retried "
            "on the next run.\nPress Enter to skip a question, or type 'd' to dismiss it for good.",
            title="Answer pending questions", border_style="yellow",
        ))
        answered = 0
        for i, q in enumerate(pending, 1):
            options = q["options"]
            console.rule(f"Question {i}/{len(pending)}")
            console.print(f"[bold]{q['question_text']}[/]")
            if q["companies"]:
                console.print(f"[dim]Asked by: {', '.join(q['companies'][:6])}[/]")
            for n, opt in enumerate(options, 1):
                console.print(f"  {n}. {opt}")
            hint = "number or text" if options else ("digits" if q["field_type"] == "number" else "your answer")
            while True:
                raw = Prompt.ask(f"Answer ({hint})", default="", show_default=False).strip()
                if not raw:
                    break
                if raw.lower() == "d":
                    db.dismiss_pending(q["question_hash"])
                    break
                if options and raw.isdigit() and 1 <= int(raw) <= len(options):
                    raw = options[int(raw) - 1]
                spec = FieldSpec(field_id="q", label=q["question_text"], field_type=q["field_type"], options=options)
                value = coerce_answer(spec, raw)
                if value is None:
                    console.print("[red]That doesn't fit this question; try again.[/]")
                    continue
                db.resolve_pending(q["question_hash"], value)
                answered += 1
                break
        console.print(f"[green]Saved {answered} answer(s).[/]")
        return 0
    finally:
        db.close()


def cmd_status(settings: Settings) -> int:
    db = Database(settings.paths.db_file)
    try:
        counts = db.status_counts()
        summary = Table(title="All-time results")
        summary.add_column("Status")
        summary.add_column("Jobs", justify="right")
        for status, n in counts.items():
            summary.add_row(status, str(n))
        console.print(summary)
        recent = Table(title="Most recent 25")
        for col in ("When (UTC)", "Company", "Title", "Route", "Status", "Notes"):
            recent.add_column(col, overflow="fold")
        for j in db.recent_jobs(25):
            recent.add_row((j["updated_at"] or "")[:16].replace("T", " "), j["company"] or "", j["title"] or "",
                           j["ats_type"] or "", j["status"] or "", (j["notes"] or "")[:90])
        console.print(recent)
        pending = len(db.list_pending())
        if pending:
            console.print(f"[yellow]{pending} question(s) waiting for your answer.[/]")
        console.print(f"[dim]Screenshots & logs: {settings.paths.logs_dir}[/]")
        return 0
    finally:
        db.close()


async def cmd_doctor(settings: Settings) -> int:
    ok_all = True

    def row(ok: bool | None, what: str, detail: str = "") -> None:
        nonlocal ok_all
        mark = "[green]✓[/]" if ok else ("[yellow]![/]" if ok is None else "[red]✗[/]")
        ok_all = ok_all and ok is not False
        console.print(f" {mark} {what}" + (f" [dim]— {detail}[/]" if detail else ""))

    console.print(Panel(f"Settings folder: {settings.paths.home}", title="Auto Applicator check-up"))
    p = settings.profile
    row(p is not None, "Profile", str(settings.paths.profile_file) if p else "run setup")
    if p:
        row(settings.resume_path.exists(), "Resume PDF", str(settings.resume_path))
    row(bool(settings.config.search_queries), "Job searches", f"{len(settings.config.search_queries)} configured")
    row(settings.secrets.imap_configured or None, "Email (IMAP) for verification codes",
        settings.secrets.imap_user if settings.secrets.imap_configured else "not set up (optional, but needed for Greenhouse/Workday codes)")
    pw = settings.secrets.ats_default_password.get_secret_value()
    row(bool(pw and pw != "StrongPortalPassword123!") or None, "Portal password (Workday accounts)", "set" if pw else "not set")
    llm = LLMClient(settings.config.llm)
    try:
        await llm.ensure_ready()
        row(True, "Local AI model", llm.text_model)
    except LLMError as e:
        row(False, "Local AI model", str(e))
    try:
        from playwright.async_api import async_playwright

        async with async_playwright() as pw_:
            from pathlib import Path

            exe = pw_.chromium.executable_path
            row(Path(exe).exists() or settings.config.browser.channel == "chrome", "Browser", exe)
    except Exception as e:  # noqa: BLE001
        row(False, "Browser", str(e))
    row(settings.paths.chrome_profile.exists() or None, "LinkedIn session", "use 'Sign in to LinkedIn' if you haven't yet")
    row(None if not schedule.is_installed() else True, "Daily schedule",
        schedule.describe(settings.config.schedule) if schedule.is_installed() else "not installed (optional)")
    row(None, "Practice mode", "ON – nothing is submitted" if settings.config.dry_run else "OFF – scheduled runs submit applications")
    console.print("[bold green]All good![/]" if ok_all else "[bold yellow]Fix the ✗ items above (re-run setup).[/]")
    return 0 if ok_all else 1


def cmd_install_schedule(settings: Settings) -> int:
    settings.require_profile()
    path = schedule.install(settings)
    mode = "dry runs (nothing submitted)" if settings.config.dry_run else "LIVE runs (applications submitted)"
    console.print(f"[green]✓ Scheduled {schedule.describe(settings.config.schedule)}: {mode}.[/]\n[dim]{path}[/]")
    console.print("[dim]Your Mac must be awake and you must be logged in at that time.[/]")
    return 0


# --------------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.setup:
            from .wizard import run_wizard

            return run_wizard(console)
        if args.app_backend:
            from .app_bridge import serve

            paths = Paths.default().ensure()
            setup_logging(paths, args.verbose)
            return serve(paths)
        settings = load_settings()
        setup_logging(settings.paths, args.verbose)
        if args.login:
            return asyncio.run(cmd_login(settings, wait_for_enter=not args.no_input))
        if args.dry_run:
            return asyncio.run(cmd_pipeline(settings, dry_run=True))
        if args.run:
            return asyncio.run(cmd_pipeline(settings, dry_run=settings.config.dry_run))
        if args.live:
            if not args.yes and not Confirm.ask(
                "[bold red]This will SUBMIT real job applications under your name.[/] Continue?", default=False
            ):
                return 1
            return asyncio.run(cmd_pipeline(settings, dry_run=False))
        if args.test_imap:
            return asyncio.run(cmd_test_imap(settings))
        if args.answer_pending:
            return cmd_answer_pending(settings)
        if args.status:
            return cmd_status(settings)
        if args.doctor:
            return asyncio.run(cmd_doctor(settings))
        if args.open_settings:
            macos.open_in_finder(settings.paths.home)
            return 0
        if args.install_schedule:
            return cmd_install_schedule(settings)
        if args.uninstall_schedule:
            removed = schedule.uninstall()
            console.print("[green]✓ Schedule removed.[/]" if removed else "No schedule was installed.")
            return 0
    except ConfigError as e:
        console.print(Panel(str(e), title="Setup needed", border_style="yellow"))
        return 2
    except (PipelineError, BrowserError, LLMError, RuntimeError) as e:
        console.print(f"[red]✗ {e}[/]")
        return 1
    except KeyboardInterrupt:
        console.print("\nStopped.")
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
