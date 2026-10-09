# mdmcheck

A single-file, read-only checker that tells you whether a Mac is still assigned to **Remote
Management (DEP/ADE)** or carries **Activation Lock** — before you erase or resell it.

Run it on the Mac you're checking, from that Mac's own macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/Vantage-Point-ITAD/mdmcheck/main/mdmcheck.sh | bash
```

Pipe to **`bash`**, not `zsh` — `bash` is present both on a full macOS boot and in Recovery, so the
same command works everywhere. (`zsh` works on a full boot too, but **Recovery has no zsh**.)

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

## Running it from macOS Recovery

It also works from **Utilities → Terminal in macOS Recovery**, which lets you check a unit without
booting it or creating an account. Join Wi-Fi from the Recovery menu bar first, then run the same
one-liner — **piped to `bash`**.

> **recoveryOS has no `zsh`.** Piping to `zsh` there fails with `zsh: command not found`, followed
> by `curl: (56) Failure writing output to destination` — that second error is just curl noticing
> the pipe's reader died, not a network problem. Recovery's `bash` is 3.2; this script avoids
> bash-4+ syntax and is tested under `sh`, `bash` and `zsh`.

In Recovery, `/` is the **recovery volume**, not the Mac you are checking — so reading `/var/db`
there would describe the recovery environment and tell you nothing about the unit. `mdmcheck`
detects Recovery, finds the unit's own internal Data volume, mounts it **read-only** if it isn't
already, reads the records from there, and unmounts it again. The volume it used is printed as
`Read:` in the output and recorded in the proof file, so the verdict is always traceable to a
specific disk.

If it cannot identify exactly one internal macOS volume it stops at **NOT CONFIRMED** rather than
guessing:

| Situation | Result |
|---|---|
| No internal macOS volume found | NOT CONFIRMED |
| More than one found | lists them, NOT CONFIRMED — re-run with `--volume <mount point>` |
| Volume won't mount (FileVault-locked) | NOT CONFIRMED |
| Elevation failed, so nothing was actually read | NOT CONFIRMED |

Recovery already runs as root, so no password is asked for there.

> **Validate once before relying on it.** The Recovery path has been exercised against real disks
> but not yet on a full Recovery boot in your environment. Run it in Recovery on a known-clean and
> a known-managed unit with `--report` and confirm the `Read:` line names the volume you expect.

## Options

```sh
curl -fsSL <url> | bash -s -- --report   # dump raw signals for calibration; verdict not acted on
curl -fsSL <url> | bash -s -- --quiet    # no popup; terminal output + proof file only
curl -fsSL <url> | bash -s -- --volume "/Volumes/Macintosh HD - Data"   # read a specific volume
curl -fsSL <url> | bash -s -- --help
```

Calibrate once on a **known-managed** and a **known-clean** machine with `--report` before trusting
verdicts in volume.

## Requirements

macOS, and either an admin account (you'll be prompted for `sudo`; the password is read from the
terminal, which works fine while the script is piped) or a root shell such as Recovery. **No Python, no Homebrew, no dependencies** — it uses
only what ships with macOS, so it runs on a freshly installed system where `/usr/bin/python3` is
still just a stub that would trigger a multi-gigabyte Command Line Tools download.

Works identically under `sh`, `bash` (including the 3.2 in Recovery) and `zsh`. That is enforced by
tests, not assumed: zsh does not
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
