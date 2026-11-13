# Auto Applicator

A Mac app that applies to jobs for you. It searches LinkedIn for jobs that match what you want, fills in the
applications (LinkedIn Easy Apply, Greenhouse, Lever, Ashby, Workday and other career sites) from **your profile**,
and reads the verification codes those sites email you. The AI that answers open questions runs **on your Mac**:
your profile, resume and answers are never sent to an AI service.

> **Practice runs are on by default.** The app fills every form and stops at the final *Submit* button, saving a
> picture for you to check. You switch to real submissions when you're comfortable.

Native Swift and SwiftUI for Apple silicon: no Python, no Terminal, no background server.

**[⬇ Download AutoApplicator.dmg](https://github.com/grabbiel/auto-applicator/releases/latest/download/AutoApplicator.dmg)**
(from the [latest release](https://github.com/grabbiel/auto-applicator/releases/latest))

---

## Installing

You need a Mac with Apple silicon (M1 or newer) and macOS 14 Sonoma or newer.

1. Open `AutoApplicator.dmg` and drag **Auto Applicator** onto **Applications**.
2. Double-click it in Applications. The first time, macOS may say it can't check the app for malicious software
   (it isn't from the App Store). Open **System Settings › Privacy & Security**, scroll to the message about
   *Auto Applicator* and click **Open Anyway**. This happens only once.
3. Click **Start setup**. Ten short steps, about five minutes, and each one explains where to click and what to
   enter:

   | Step | What happens |
   |---|---|
   | Your resume | Drop your resume PDF. The app reads it and fills in most of the next steps. |
   | About you · Work & pay · Experience | Check what it found. These answer the questions almost every form asks. |
   | Jobs to find | Job titles, location, remote/hybrid/on-site, level, companies to avoid, how many per run. |
   | AI helper | Apple Intelligence (macOS 26, nothing to download) or a free model through Ollama (~5 GB). |
   | LinkedIn | Sign in once, on LinkedIn's own page inside the app. |
   | Email codes | Optional: an app password so it can read the codes some sites email you. |

To update, download the newer disk image and drag the app over the old one. Your data is kept.

**To remove it:** quit it, move it to the Trash, and delete `~/Library/Application Support/AutoApplicator`.

## Using it

| Page | What's there |
|---|---|
| **Today** | Start a practice run or apply for real, the daily schedule, and what needs your attention. |
| **Live** | Watch the browser fill in a form as it happens, with a *Stop* button. |
| **Questions** | Questions it couldn't answer from your profile. Answer once and the skipped jobs are retried. |
| **Applications** | Every job and what happened to it, with the picture of the filled form. |
| **What it knows** | Your past answers and the facts you taught it, and what to add next. |
| **Profile** · **Job search** · **Settings** | Everything from setup, editable, plus the AI, email, schedule and cloud browser. |

The search box at the top (⌘F) finds any job, company, waiting question, remembered answer or setting.

**It learns as you go.** Every answer you give is remembered. A question worded like one you already answered reuses
that answer, and the most relevant facts are given to the AI as evidence it must quote. It never guesses: when a
required question can't be answered from what you told it, the job is skipped and the question waits on the
*Questions* page.

**Closing the window quits the app** and stops everything it started (the browser, Ollama if the app launched it,
the run). A daily scheduled run opens the app by itself and quits it when done; your Mac must be awake.

A job ends in one of these states: `APPLIED`, `DRY_RUN_COMPLETE` (practice), `SKIPPED_NEEDS_ANSWER`,
`SKIPPED_BLACKLIST`, `SKIPPED_TITLE_FILTER`, `SKIPPED_ALREADY_APPLIED`, `FAILED_OTP_TIMEOUT`, `FAILED_FORM_ERROR`.
Failed jobs are retried on later runs.

### Where your data lives

```
~/Library/Application Support/AutoApplicator/      (AA_HOME=/some/folder uses another one)
├── profile.json  settings.json  secrets.json      secrets.json is readable only by you (0600)
├── files/resume.pdf
├── data/jobs.db                                   jobs, remembered answers, facts, pending questions
├── evidence/                                      pictures of filled forms, cover letters
├── logs/                                          app.log
└── tools/                                         Ollama, only if you chose it
```

The app itself contains no personal data, so it can be shared. Settings from version 0.3 (`profile.yaml`,
`config.yaml`, `.env`) are carried over on first launch.

### Good to know

- **LinkedIn's terms prohibit automated activity**, and accounts that automate can be restricted. Keep runs small
  and review your practice runs.
- You're responsible for what's submitted under your name.
- It doesn't solve "verify you're human" checks. A job that shows one fails and is listed in *Applications*.
- Career sites change their pages over time; some will end in `FAILED_FORM_ERROR`, with a picture showing why.

## Cloud browser (optional)

Runs can load pages in Chrome on AWS
([Amazon Bedrock AgentCore Browser](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/browser-tool.html))
instead of in the app's own browser. This Mac still directs each run and its AI still answers the questions; only the
browsing happens remotely. You sign in on a hosted page with an email and password, or a passkey (Touch ID / iCloud
Keychain), and stay signed in for 30 days.

Set it up in your AWS account with an admin profile, then rebuild the app so it knows where the browser is:

```bash
bash scripts/deploy_cloud.sh --invite you@example.com
```

```bash
bash scripts/build_app.sh
```

`deploy_cloud.sh` deploys [`infra/cloud-browser.yaml`](infra/cloud-browser.yaml) (stack `auto-applicator-cloud`,
us-east-1 by default) and writes `Resources/CloudConfig.json`, which the build bundles. That file names your
account, so it's ignored by git. `--invite` creates the one sign-in account; Cognito emails that address a
temporary password. Then, in the app: **Settings › Cloud browser › Sign in**, choose a new password, and
**Add a passkey** for next time.

What it creates, all tagged `App=auto-applicator` (the resource group `auto-applicator` lists them):

| Resource | Purpose |
|---|---|
| Cognito user pool, hosted sign-in domain, app client | Sign-in with password or passkey; code + PKCE, no client secret; 30-day refresh token; no self sign-up |
| Cognito identity pool and an IAM role | Temporary AWS credentials that can only start, use, stop and save sessions of this one browser |
| AgentCore custom browser and browser profile | Chrome sessions; the profile keeps cookies between runs |

**Cost:** nothing while idle. A session is billed only while it runs (CPU and memory per second), and Cognito is
free for one user. Each session ends after its run, or after a timeout matched to the run's size (1–8 hours).

**Remove it:**

```bash
aws cloudformation delete-stack --stack-name auto-applicator-cloud
```

LinkedIn may ask you to sign in again, or verify, when it sees you from an AWS address. *Settings › Cloud browser ›
Test it* shows what LinkedIn sees.

---

## For developers

**Xcode 26 or newer** (its SDK has Apple's on-device AI framework); releases use Xcode 27, whose SDK also tells the
app how much text macOS 27's on-device model accepts. Apple silicon only.

```
Sources/Engine/          everything that isn't UI
  Apply/                 LinkedIn search and Easy Apply, career-site handlers, the run loop
  Browser/               WebAgent (WKWebView, or the cloud browser over the DevTools protocol), form reading/filling
  Answers/               answer resolution: memory → profile rules → AI, option matching, evidence grounding
  AI/                    Apple Intelligence (FoundationModels) and Ollama, behind one LanguageModel protocol
  Email/                 IMAP (Network.framework, TLS), MIME, code and link extraction
  Cloud/                 Cognito sign-in, SigV4, AgentCore browser sessions
  Data/ Model/ Resume/   SQLite, profile/settings/secrets, PDF reading and writing
  System/                launchd schedule, the helper-process supervisor
Sources/AutoApplicator/  the SwiftUI app
tests/EngineTests/       unit and browser tests against local HTML fixtures (no network)
infra/                   CloudFormation for the cloud browser
scripts/                 build, package, icon, disk-image background, cloud deploy
```

Build and test:

```bash
swift build
```

```bash
swift test
```

```bash
bash scripts/build_app.sh
```

```bash
bash scripts/package.sh
```

`build_app.sh` makes `build/Auto Applicator.app` (ad-hoc signed). `package.sh` makes `dist/AutoApplicator.dmg`: the
app, a shortcut to Applications on a styled background, and *How to install.txt*. Set `AA_CLOUD_CONFIG=none` to
leave your cloud browser out of a copy for other people. With an Apple Developer ID,
`AA_SIGN_IDENTITY="Developer ID Application: …"` signs it and `AA_NOTARY_PROFILE=<notarytool profile>` also
notarizes it, so it opens without the *Open Anyway* step.

The form and handler tests also run against the real cloud browser when asked:

```bash
eval "$(aws configure export-credentials --profile admin --format env)" && AA_CLOUD_TEST=1 swift test --filter Cloud
```

**Helpers and quitting.** Every process the app starts (Ollama) runs under a small supervisor in its own process
group that watches the app's process: when the app quits, crashes or is force-quit, the helper is asked to stop and
is killed if it hasn't within five seconds. A helper that outlives a hard crash is stopped on the next launch.

**Seeing every screen without clicking:** `AA_HOME=$(mktemp -d) AA_DEMO=1 AA_SNAPSHOTS=/some/folder` on the built
app fills a temporary folder with sample data, saves a PNG of each screen and quits (`AA_DARK=1` for dark mode,
`AA_SNAPSHOT_ONLY=name,…` for some of them). See `Sources/AutoApplicator/DebugHooks.swift`.

### Releases

Bump `VERSION`, then push a matching tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds and tests on macOS, packages the disk image
(without a cloud configuration) and attaches it to a GitHub release, which the download link above always points to.

It needs Xcode 27 or newer, which GitHub's Mac machines don't have yet: until they do, its run stops before building
and publishes nothing. Build and publish from a Mac with Xcode 27 instead, after pushing the tag:

```bash
swift test --skip LiveAITests --skip Cloud
```

```bash
AA_CLOUD_CONFIG=none bash scripts/package.sh
```

```bash
gh release create v1.0.0 dist/AutoApplicator.dmg --title "Auto Applicator 1.0.0" --generate-notes --verify-tag
```
