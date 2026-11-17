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

From version 1.2.0 on, the app updates itself (see [Updates](#updates)). Before that, download the newer disk image
and drag the app over the old one. Your data is kept either way.

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

### Updates

Every few hours the app checks the newest release on GitHub. When there's a new version, it downloads it, and the
**Update** button appears at the top. The new version installs the next time the app quits (also after a daily run),
or right away with **Restart now**. Turn this off under **Settings › Updates**, which also has **Check now**; the app
menu has **Check for Updates…** too.

Before installing, the app checks that the download is exactly the published disk image (size and SHA-256 from the
release's `update.json`), that it holds the same app at the promised version, and that its signature is intact
(and, for apps signed with a Developer ID, from the same developer). It then swaps the new app in, in one step, so
the old one stays whole until the new one is in place.

If macOS doesn't let the app replace itself, it says so and offers the disk image to drag over. That happens when it
runs from the disk image or a download folder, from an account that can't change Applications, or when macOS asks
for **App Management** permission (System Settings › Privacy & Security).

## Cloud browser (optional)

Runs can load pages in Chrome on AWS
([Amazon Bedrock AgentCore Browser](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/browser-tool.html))
instead of in the app's own browser. This Mac still directs each run and its AI still answers the questions; only the
browsing happens remotely. It's invite-only: an invited address signs in on a hosted page with its password, a
passkey (Touch ID / iCloud Keychain), or, once you've set them up, Google or Apple, and stays signed in for 30 days.

Set it up in your AWS account with an admin profile, then rebuild the app so it knows where the browser is:

```bash
bash scripts/deploy_cloud.sh --invite you@example.com
```

```bash
bash scripts/build_app.sh
```

`deploy_cloud.sh` deploys [`infra/cloud-browser.yaml`](infra/cloud-browser.yaml) (stack `auto-applicator-cloud`,
us-east-1 by default) and writes `Resources/CloudConfig.json`, which the build bundles. That file names your
account, so it's ignored by git. `--invite` creates the sign-in account; Cognito emails that address a
temporary password. Then, in the app: **Settings › Cloud browser › Sign in**, choose a new password, and
**Add a passkey** for next time.

**Invitations.** Nobody can sign up. `--invite` again resends an invitation that hasn't been used; `--invites` lists
who's invited and how each person signs in; `--revoke` stops someone at once (`--invite` lets them back):

```bash
bash scripts/deploy_cloud.sh --invites
```

**Google and Apple.** These add *Continue with Google* and *Continue with Apple* to the sign-in page. They're still
invite-only: a first Google or Apple sign-in works only if its verified email has an invitation, and is then joined to
that account (password, passkey, Google and Apple all reach the same one). Apple's *Hide My Email* addresses don't
match an invitation. You create the sign-in client at Google (free) and Apple (needs the Apple Developer Program);
this prints exactly what to enter there:

```bash
bash scripts/deploy_cloud.sh --sign-in-setup
```

```bash
bash scripts/deploy_cloud.sh --google <client ID>
```

```bash
bash scripts/deploy_cloud.sh --apple <Services ID> --apple-team <team ID> --apple-key <key ID> --apple-key-file AuthKey_<key ID>.p8
```

The Google secret is typed at a hidden prompt and the Apple key is read from its file; both go to Cognito in a file
only the script can read, never on a command line or through CloudFormation. `--google off` or `--apple off` removes
them. Rebuild the app afterwards so Settings names them.

What it creates, all tagged `App=auto-applicator` (the resource group `auto-applicator` lists them):

| Resource | Purpose |
|---|---|
| Cognito user pool, hosted sign-in domain, app client | Sign-in with password, passkey, Google or Apple; code + PKCE, no client secret; 30-day refresh token; no self sign-up |
| Invite gate (Lambda function, its role and a 30-day log) | Lets a first Google or Apple sign-in in only for an invited address, and joins it to that account |
| Cognito identity pool and an IAM role | Temporary AWS credentials that can only start, use, stop and save sessions of this one browser |
| AgentCore custom browser and browser profile | Chrome sessions; the profile keeps cookies between runs |

**Cost:** nothing while idle. A session is billed only while it runs (CPU and memory per second), Cognito is free
for one user, and the invite gate runs only on a first Google or Apple sign-in. Each session ends after its run, or after a timeout matched to the run's size (1–8 hours).

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

A release is a fix or improvement worth sharing: raise `VERSION` in its pull request (`1.2.0` → `1.2.1` for fixes,
`1.3.0` for something new). When it's merged, [`release.yml`](.github/workflows/release.yml) tests the app, builds
the disk image (never with a cloud browser address) and publishes `v<VERSION>` with install steps and the merged pull
requests as its notes. The download link at the top always points to the newest one. Last, it adds `update.json`
([`make_update_manifest.swift`](scripts/make_update_manifest.swift)); from then on, every copy of the app offers the
new version to install.

To try an update before releasing it, point a copy with a test data folder at a local `update.json`:
`AA_HOME=<temp folder> AA_UPDATE_FEED=file:///…/update.json` (its `url` can be a `file://` disk image).
A copy with a built-in cloud configuration saves it to the data folder (`cloud.json`) on launch, so updating your
own copy to a public release keeps the cloud browser and cloud AI.

- Pull requests and main are built and tested by [`test.yml`](.github/workflows/test.yml).
- Both run on GitHub's `xcode-27` Mac image, which is still a preview: a run can wait in the queue for a machine,
  and re-running a failed run is safe (it never publishes the same version twice).
- **Actions › Release › Run workflow** builds the disk image only, as a download on the run's page, to try before
  releasing.
- Pushing a tag `v<VERSION>` publishes that commit, or replaces the disk image of a release that exists.

If GitHub's Macs can't build it, publish from your Mac (Xcode 27, on main as pushed) instead:

```bash
bash scripts/publish_local.sh
```

**Signing.** Without signing secrets the app is ad-hoc signed, and the first open needs **Open Anyway** in System
Settings › Privacy & Security. With an Apple Developer Program membership, add these repository secrets and releases
are signed with your Developer ID and notarized, so the app opens like any other:

| Secret | What it holds |
|---|---|
| `MACOS_CERTIFICATE_P12` | Your *Developer ID Application* certificate with its private key, exported from Keychain Access as a .p12 file, in base64 |
| `MACOS_CERTIFICATE_PASSWORD` | The password you gave that .p12 |
| `NOTARY_KEY_P8` | An App Store Connect API key (Users and Access › Integrations › Team Keys, role *Developer*): the .p8 file |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER` | The Issuer ID shown above the keys |

Add them under Settings › Secrets and variables › Actions, or from the folder holding the files:

```bash
base64 -i cert.p12 | gh secret set MACOS_CERTIFICATE_P12
```

```bash
gh secret set NOTARY_KEY_P8 < AuthKey_XXXXXXXXXX.p8
```

(`gh secret set NAME` with no input asks for the value, for the other three.) The signature shows the name on the
Apple account to anyone who inspects the app.
