# mdmcheck

A single-file, read-only checker that tells you whether a Mac is still assigned to **Remote
Management (DEP/ADE)** or carries **Activation Lock** — before you erase or resell it.

Run it on the Mac you're checking, from that Mac's own macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/Vantage-Point-ITAD/mdmcheck/main/mdmcheck.sh | zsh
```

It prints a verdict, shows a popup, and writes a timestamped proof file to
`~/Desktop/MDM Checks/`.

---

## What it is, and what it is not

**It is a detector.** It reads status and reports it.

**It is not a bypass.** It does not remove profiles, does not suppress or skip the Remote
Management screen, and does not help you take a managed Mac away from its owner. It never writes
to the disk it inspects. If a Mac comes back MANAGED, the fix is to have the rightful owner
release it from their MDM/ABM — this tool will not do anything else for you.

---

## Verdicts

| Verdict | Meaning | Trust |
|---|---|---|
| **MANAGED** | On-disk DEP/MDM activation records found, **or** Activation Lock is on, **or** the cloud query returned a real enrollment configuration. | Reliable |
| **CLEAN** | The activation records were read directly and hold **no** DEP/MDM assignment, and Activation Lock is off. | Reliable — this is ground truth from the disk |
| **NOT CONFIRMED** | The records could not be read. | **Not a clearance.** Verify at the Setup Assistant "Remote Management" screen. |

### Why it reads the disk instead of asking Apple

`profiles show -type enrollment` — the cloud DEP query — is **unreliable in both directions**. On
genuinely DEP-managed Macs it has been observed to *both* hard-fail (Apple error `34000`) *and*
falsely report "not assigned". A cloud "no" therefore proves nothing and can never earn CLEAN here.
The on-disk activation record is what the device actually holds, so that is the authority; the
cloud query is kept only as a secondary signal.

### The `.cloudConfig*` trap

Setup Assistant writes a receipt of its DEP check **either way**:

| On-disk file | Means |
|---|---|
| `.cloudConfigRecordFound`, `.cloudConfigHasActivationRecord`, `.cloudConfigProfileInstalled` | the device **is** assigned |
| `.cloudConfigRecordNotFound`, `.cloudConfigNoActivationRecord` | Apple answered **"not assigned"** — a *clean* receipt |

Every clean Mac that completed setup online has one of the negative receipts on disk. Tools that
glob `.cloudConfig*` and treat any match as "managed" will flag clean machines as managed — we
shipped that bug once and fixed it. `mdmcheck` classifies the names, and **any unrecognised
`.cloudConfig*` name still counts as managed**, so an unknown record is never silently cleared.

---

## Options

```sh
curl -fsSL <url> | zsh -s -- --report   # dump raw signals for calibration; verdict not acted on
curl -fsSL <url> | zsh -s -- --quiet    # no popup; terminal output + proof file only
curl -fsSL <url> | zsh -s -- --help
```

Calibrate once on a **known-managed** and a **known-clean** machine with `--report` before trusting
verdicts in volume.

## Requirements

macOS, an admin account, and `sudo` (you'll be prompted; the password is read from the terminal,
which works fine while the script is piped). **No Python, no Homebrew, no dependencies** — it uses
only what ships with macOS, so it runs on a freshly installed system where `/usr/bin/python3` is
still just a stub that would trigger a multi-gigabyte Command Line Tools download.

Works identically under `bash` and `zsh`. That is enforced by tests, not assumed: zsh does not
word-split unquoted variables, so a loop that is correct in bash can silently iterate once under
zsh — which in this script would have been enough to reintroduce the false positive above.

---

## Running code straight from the internet

`curl … | zsh` executes whatever the URL returns, at the moment you run it. That is a real trust
decision, so make it deliberately:

- **Read it first.** It's one file, ~350 lines, deliberately kept readable:
  `curl -fsSL <url> | less`
- **This URL tracks `main`**, so benches always get the current version — and a bad push reaches
  every bench immediately. Pin a tag instead if you want a fixed version:
  `.../mdmcheck/v2.0.0/mdmcheck.sh`
- **Use HTTPS** (as above). Never fetch a script you're about to execute over plain HTTP.
- **Vendor it** if you'd rather not depend on GitHub at bench time: copy the file to your own
  server or a USB stick. It is self-contained on purpose.

## Proof files

Each run writes `~/Desktop/MDM Checks/<serial>_<timestamp>.txt` with the serial, model, macOS
version, verdict, findings, and the raw command output behind it, plus a one-line entry in
`mdm_checks.txt`.

**If the Mac is about to be erased, that proof dies with it** — record the verdict on the unit's
paperwork *before* wiping.

---

## Credits & licence

MIT — see [LICENSE](LICENSE).

The on-disk activation-record technique was learned from the *detection* routine of the
MIT-licensed `unleash` project. It was reimplemented from scratch here, and **none of that
project's bypass code is used or reproduced**.
