# Auto Applicator

A local job-application assistant for macOS. It searches LinkedIn for jobs that match your criteria, fills in
the application forms (LinkedIn Easy Apply, Greenhouse, Lever, Ashby, Workday and other career sites) from
**your profile**, using a **local AI model** that runs on your Mac, and can read the verification codes those
sites email you. Everything runs on your machine: your profile, resume and answers are never sent to a cloud AI.

> **Practice runs are on by default.** The app fills every form and stops at the final *Submit* button, saving a
> screenshot for you to review. You switch to real submissions when you're comfortable.

---

## What it does

| Step | How |
|---|---|
| Find jobs | Builds LinkedIn search URLs from your keywords, location, remote/hybrid, experience level and date posted; scrolls the results so every card loads; skips jobs you already handled, blacklisted companies and excluded titles. |
| Fill applications | Reads every field on the form (text boxes, dropdowns, radio buttons, checkboxes, Yes/No buttons, file uploads) and answers it: **1)** answers you gave before → **2)** your profile (name, contact, work authorization, salary, years of experience, EEO…) → **3)** the local AI model, which must quote the part of your profile the answer is based on. |
| Never guess | If a **required** question can't be answered from your profile with confidence (e.g. "Years of experience with Rust?" when Rust isn't in your profile, or "Have you ever been convicted…?"), the job is **skipped and the question is saved**. You answer it once on the app's *Questions* page; the answer is reused forever and the job is retried. |
| Validation errors | When a form rejects an answer, the error message is fed back to the model to fix it (up to 2 retries). |
| Email codes & links | Greenhouse's 8-character security code and Workday's account-verification link are read from your inbox (IMAP, read-only search). |
| Accounts | Workday portals need a candidate account: the app signs in or creates one with your application email and a generated password (kept in your private `.env`). |
| Cover letters | Uses your cover letter PDF if you set one; otherwise writes a short tailored one when a site requires it. |
| Records | Every job and its outcome is stored in a local database; screenshots and logs go to your settings folder. |

**What it does not do:** it doesn't solve or get around "verify you're human" checks (CAPTCHAs). If a site
shows one, that application fails and is listed in the results; the browser window stays open so you can finish
it yourself if you like.

---

## For the person receiving the app (installation)

**[⬇ Download AutoApplicator.dmg](https://github.com/grabbiel/auto-applicator/releases/latest/download/AutoApplicator.dmg)**
(from the [latest release](https://github.com/grabbiel/auto-applicator/releases/latest)).

**Requirements:** a Mac (Apple Silicon recommended) with macOS 13 or newer, **16 GB RAM or more**, ~10 GB free
disk space, and an internet connection for the one-time download. No admin password, Terminal, Homebrew or
developer tools are needed.

1. **Open `AutoApplicator.dmg`** and **drag `Auto Applicator` onto the `Applications` folder** in that window.
2. **Double-click it in Applications.** The first time, macOS says it can't check the app for malicious software
   (it isn't notarized by Apple). Open **System Settings → Privacy & Security**, scroll to the message about
   *Auto Applicator* and click **Open Anyway**. (macOS 13–14: right-click the app → *Open* → *Open*.) This
   happens only once.
3. Click **Set up**. A progress bar shows the app downloading its components (~1–2 minutes), then the setup
   screens appear in the app's window. While you fill them in, it downloads the rest in the background: the
   app's private browser and the local AI (Ollama plus a model sized for your Mac: `qwen2.5:7b` (~5 GB) for
   16 GB Macs, `qwen2.5:14b` (~9 GB) for 32 GB+). The badge at the top right shows the progress.
4. From then on, open **Auto Applicator** from Applications or the Dock.

Everything the app installs goes into `~/Library/Application Support/AutoApplicator` (an Ollama you already have
is reused). The *How to install.txt* inside the disk image says the same in plain words. To update, download the
newer disk image and drag the app over the old one: your settings are kept.

### Setting up (first launch)

Eight short steps in the app window, with *Back* and *Continue* buttons; missing required fields are marked in red:

1. **Welcome** – what the app does and what will be installed.
2. **Your resume** – choose or drop your resume PDF. The local AI reads it and fills in the next pages for you
   (you can keep typing meanwhile; it never overwrites what you typed).
3. **About you** – name, email, phone, city, LinkedIn/GitHub/website.
4. **Work & pay** – work authorization, sponsorship, salary, start date, relocation, and the optional
   voluntary questions (gender, ethnicity, veteran, disability – "Decline to self-identify" is always fine).
5. **Your experience** – total years, years per skill, skills, jobs you've had, education.
6. **The jobs you want** – job titles (one search each), location, remote/hybrid/on-site, level, posted within,
   Easy Apply only or company websites too, companies and title words to avoid, how many per run, practice mode
   on/off, and an optional daily schedule.
7. **Email codes** – optional: lets the app read the verification codes some job sites email you. It explains,
   for Gmail, iCloud, Yahoo and Outlook, how to create the *app password* it needs, and tests it for you.
8. **Almost done** – saves everything, then two buttons: **Sign in to LinkedIn** (opens the app's browser; sign
   in once) and **Try a practice run**.

To change anything later: **My details & job search** in the sidebar (the same pages, with a *Save changes* button).

### Everyday use

| Page | What's there |
|---|---|
| **Home** | **Start a practice run** (searches and fills applications, stops before *Submit*, saves screenshots) and **Apply for real** (same, but submits; asks you to confirm first). Progress shows right on the page, with a *Stop* button. Also: LinkedIn sign-in status, email codes, practice mode, the daily schedule switch, **Check setup**, the practice-run pictures and the settings folder. |
| **Questions** | Questions that made jobs get skipped. Answer once; the answer is reused and those jobs are retried on the next run. |
| **Results** | Recent jobs and what happened to each (double-click to open the job). |
| **My details & job search** | Everything from setup, editable. |

The daily schedule runs automatically at the time you chose (weekdays by default) and honours practice mode. Your
Mac must be awake and logged in.

A job ends in one of these states: `APPLIED`, `DRY_RUN_COMPLETE`, `SKIPPED_NEEDS_ANSWER`, `SKIPPED_BLACKLIST`,
`SKIPPED_TITLE_FILTER`, `SKIPPED_ALREADY_APPLIED`, `FAILED_OTP_TIMEOUT`, `FAILED_FORM_ERROR`. Failed jobs are
retried on later runs (up to `max_attempts_per_job`).

---

## Where your data lives

```
~/Library/Application Support/AutoApplicator/
├── config.yaml        search queries, filters, limits, dry_run, model, schedule
├── profile.yaml       everything the app may say about you
├── .env               email app password + portal password (permissions 600)
├── app/               the app's code and Python environment (replaced when you open a newer version)
├── tools/             uv, and Ollama if it wasn't already installed
├── files/resume.pdf   copy of your resume
├── data/jobs.db       jobs, saved answers (qa_cache), pending questions
├── data/chrome_profile/  the app's browser profile (your LinkedIn session)
└── logs/              daily logs, screenshots/, cover_letters/
```

The app itself contains no personal data, so it can be shared safely. To use a different location (e.g. for
testing), set `AA_HOME=/some/folder`.

## Configuration reference

- **`config.yaml`**: the fully commented template is [`config.yaml`](config.yaml) in the app folder. Key settings:
  `search_queries[]` (`keywords`, `location`, `workplace_type`, `experience_level`, `date_posted`,
  `include_external`, `max_pages`), `filters`, `limits` (`max_applies_per_run`, delays, `otp_timeout_sec`,
  `max_form_steps`, `max_attempts_per_job`), `dry_run`, `llm` (`base_url`, `text_model`, `num_ctx`), `browser`
  (`channel: chromium | chrome`), `schedule`.
- **`profile.yaml`**: see [`profile.example.yaml`](profile.example.yaml). `extra_answers` lets you add your own
  "question: answer" pairs that are matched by similar wording.

## Memory & performance notes (16 GB Macs)

- `qwen2.5:7b` uses ~5 GB while active; Ollama unloads it after 5 idle minutes. The app's browser uses ~1–2 GB.
  Close heavy apps during a run if your Mac feels slow.
- The app creates a model alias `<model>-ctx8192` with an 8k-token context window (no extra download) so long
  forms fit.
- A typical Easy Apply takes 30–90 seconds including deliberate pauses between steps (`min_delay_sec`/`max_delay_sec`).

## Good to know

- **LinkedIn's terms of service prohibit automated activity.** Accounts that automate can be restricted. Keep
  `max_applies_per_run` modest, keep the pauses, and review what the app does in dry runs.
- You're responsible for what's submitted under your name: review dry-run screenshots and your `profile.yaml`.
- Workday and custom career sites vary a lot; some will fail with `FAILED_FORM_ERROR` (the note and screenshot say
  why). LinkedIn and the ATS sites change their pages over time, which can break selectors.
- Verification emails must arrive in the inbox you configured (check your spam filters).

## Sharing the app with someone else

The easiest way is the GitHub release: send the person the
[download link](https://github.com/grabbiel/auto-applicator/releases/latest/download/AutoApplicator.dmg). To build
the disk image yourself:

```bash
bash scripts/package.sh
```

creates `dist/AutoApplicator.dmg` (a few MB): the app, a shortcut to Applications and *How to install.txt*. The
app bundles an explicit allowlist of code files (never your settings folder, and never other files you drop in
the project folder; the build stops if it finds anything that looks like a secret). A newer disk image updates
the recipient's app in place and keeps their settings.

The app is signed ad hoc, so the recipient has to click *Open Anyway* once (Installation step 2). With an Apple
Developer ID you can avoid that: `AA_SIGN_IDENTITY="Developer ID Application: …" AA_NOTARY_PROFILE=<profile>
bash scripts/package.sh` signs, notarizes and staples it (create the profile with `xcrun notarytool
store-credentials`).

## Troubleshooting

| Problem | Fix |
|---|---|
| "Auto Applicator can't be opened" / "Apple could not verify…" | System Settings → Privacy & Security → *Open Anyway* (see Installation step 2). |
| The first download stopped or failed | Open the app again: it continues where it stopped. If a later download fails, click the badge at the top right and *Retry*. Details: `logs/install.log`. |
| "Not signed in to LinkedIn" | Home → LinkedIn → *Sign in*. |
| "The local AI server (Ollama) is not running" | Open the app (it starts the AI), or open the Ollama app if you installed it yourself. |
| "Model … is not installed" | Open the app and wait for the badge at the top right to show *Ready*. |
| Email test fails | Gmail/iCloud/Yahoo/Outlook need an app password, not your normal password; the *Email codes* page explains how. |
| Many `SKIPPED_NEEDS_ANSWER` | Answer them on the *Questions* page; add skills and years under *My details & job search → Experience*. |
| The browser is already open | Only one run at a time; close the other run's browser window. |
| Details | Logs: `~/Library/Application Support/AutoApplicator/logs/` (`app-helper.log`, `install.log`, daily logs). |

---

## For developers

Python 3.12+, managed with [uv](https://docs.astral.sh/uv/); the app's window is SwiftUI (macOS 13+), compiled
with `swiftc` from the Xcode command line tools (`xcode-select --install`; no Xcode project needed).

```bash
uv sync                               # install with dev dependencies
uv run playwright install chromium    # browser for the integration tests
uv run pytest                         # unit + browser tests (local HTML fixtures and fake servers, no network)
./aa --help                           # CLI (what the app's buttons run)
./aa --setup                          # the Terminal setup wizard, still available
bash setup.sh                         # build build/Auto Applicator.app and open it
bash scripts/build_app.sh [out_dir]   # just build the app (universal binary, ad-hoc signed)
bash scripts/package.sh               # build dist/AutoApplicator.dmg
```

Set `AA_HOME=/some/folder` to keep test runs away from your real settings (the app honours it too), and
`AA_DEFAULT_MODEL=qwen2.5:7b` to stop setup from picking the larger model on a big-memory Mac. With
`AA_DEBUG_DIR=/some/folder` the app reads test commands from `commands.txt` there and can save pictures of its
window (see `macos/App/DebugHooks.swift`).

**How the app works:** `Auto Applicator.app` is a native SwiftUI app carrying the Python code in
`Contents/Resources/app`. On each launch, `macos/launcher.sh install-code` copies that code to
`~/Library/Application Support/AutoApplicator/app` when its `.build-stamp` changed (so the app works from
anywhere, including a quarantined or translocated copy), and `launcher.sh bootstrap` downloads uv
(checksum-verified) and runs `uv python install` + `uv sync --frozen --no-dev`, reporting progress to the window.
The app then starts `python -m src.main --app-backend` (`src/app_bridge.py`) and talks to it with one JSON
message per line over its standard input and output: no web server, no browser page, nothing listening on the
network. The helper runs `src/installer.py` (browser, Ollama, model) in the background and exits when the app
quits. Runs (*Practice run*, *Apply for real*, *Check setup*) are `python -m src.main --dry-run | --live --yes |
--doctor` processes whose output streams into the Home page.

| Module | Responsibility |
|---|---|
| `src/main.py` | CLI: `--setup --login --dry-run --run --live --test-imap --answer-pending --status --doctor --open-settings --install-schedule --uninstall-schedule` (and `--app-backend`, for the app) |
| `src/config.py` | Pydantic models + loaders for `config.yaml`, `profile.yaml`, `.env`; settings-folder paths |
| `src/db.py` | SQLite: `jobs`, `qa_cache` (SHA-256 of normalized label + type + sorted options), `pending_questions` |
| `src/llm.py` | OpenAI-compatible client (Ollama) with strict JSON-schema outputs: `FormStepResponse`, `CoverLetterResponse`, `EmailVerificationSchema`, `ResumeJSON` → `ResumeExtraction` |
| `src/answers.py` | Answer resolution (cache → profile rules → LLM), option matching, evidence grounding, skip-and-flag policy |
| `src/forms.py` | Form-control discovery (labels/options/required/errors, `data-auto-id` tagging) and filling |
| `src/browser.py` | Persistent Chromium profile, LinkedIn session check, external-application tab handling |
| `src/scraper.py` | LinkedIn search URLs, virtual-list scrolling, card parsing, filters, job details |
| `src/email_verifier.py` | Async IMAP polling, regex extractors (8-char Greenhouse codes, 6-digit OTPs, verification links), LLM fallback |
| `src/handlers/` | `easy_apply.py`, `greenhouse.py`, `lever.py`, `ashby.py`, `workday.py`, and `base.py` (shared step loop + `GenericAXTreeHandler` for unknown portals) |
| `src/pipeline.py` | Orchestration: search → filter → route → record → summary |
| `src/app_bridge.py` | The app's helper: JSON-lines requests (draft, resume upload/import, email test, save, LinkedIn sign-in, questions, results, schedule) |
| `src/setup_gui.py` | Setup logic behind the app's screens: profile/config ↔ form conversion, resume import merge, validation, saving (`.env` with mode 600) |
| `src/installer.py` | Background installs: Chromium, Ollama (downloaded into `tools/` if missing), the model; RAM-based model choice |
| `src/wizard.py` | Terminal setup wizard with resume import |
| `src/schedule.py` | launchd agent from `scripts/com.local.auto-applicator.plist` |
| `macos/App/*.swift` | The native app: first-run download, setup screens, Home / Questions / Results / My details pages, run output |
| `macos/launcher.sh` | Code install/update into the support folder and the first-run bootstrap (uv, Python, dependencies) |
| `scripts/build_app.sh`, `scripts/package.sh`, `setup.sh`, `aa` | Build the app, build the disk image, developer helper, CLI wrapper |
