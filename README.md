# IbexConnect

A small Mac app for running GPU jobs on KAUST's Ibex cluster without living in a terminal: see which GPUs are free, start a Jupyter session or a batch job, watch its output, and get a working `localhost` link for Jupyter — the SSH tunnel is handled for you.

**Download:** <https://sattamaltwaim.github.io/IbexConnect/>

## What it does

- **GPU availability** — free GPUs on Ibex by type (A100, V100, …), refreshed every 30 s.
- **Jupyter in one click** — submits the job, waits for the node, opens the tunnel, and gives you a link with its access token. Paste it into a browser or VS Code.
- **Batch jobs** — pick GPUs, time, memory and CPUs, paste a command, submit.
- **Live output** — the job's stdout/stderr streams into the app.
- **Uploads** — copy files or folders to your home on Ibex.
- **Clear failures** — if sign-in fails the app says why: no VPN, wrong password, unregistered key, changed host key.

## Signing in

IbexConnect drives the system `ssh`. You can sign in with your **KAUST password** (kept in your Keychain if you ask) or with an **SSH key** registered on Ibex. Off campus you need the KAUST VPN first; the login window will tell you if you forgot.

## Requirements

macOS 15 or later. The download is not notarised, so the first launch needs a right-click → Open, or *System Settings → Privacy & Security → Open Anyway*.

## Building from source

Open `IbexConnect.xcodeproj` in Xcode 26 and run. There are no dependencies.

## Not affiliated with KAUST

This is a personal project. Ibex is operated by KAUST's Supercomputing Core Lab; all cluster policies and support are theirs, not this app's.
