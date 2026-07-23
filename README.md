# Telegram + Claude Bot

A small bot that connects Telegram to Claude. Message the bot, and it forwards
your message to Claude and replies with the answer.

## Where your secrets go

**Never type your API key or bot token directly into any code file.** This
project reads them from a file called `.env`, which is listed in
`.gitignore` so it can never accidentally get committed or shared. You will
create this file yourself in Step 3 below.

## Step-by-step setup

### 1. Install Python

You need Python 3.10 or newer. Check if you already have it by opening a
terminal and running:

```
python3 --version
```

If that fails or shows an old version, install Python from
[python.org/downloads](https://www.python.org/downloads/).

### 2. Install the project's dependencies

In a terminal, move into this project's folder, then run:

```
pip install -r requirements.txt
```

This installs the Telegram library, the Anthropic (Claude) library, and a
small helper that loads your `.env` file.

### 3. Create your `.env` file with your secrets

1. In this folder, make a copy of `.env.example` and name the copy `.env`.
   - Mac/Linux terminal: `cp .env.example .env`
   - Windows: right-click `.env.example` → Copy, then paste and rename to `.env`
2. Open `.env` in any text editor (Notepad, TextEdit, VS Code, etc.).
3. Paste your **Telegram bot token** after `TELEGRAM_BOT_TOKEN=`
   (get this from the BotFather step below if you don't have one yet).
4. Paste your **Anthropic API key** after `ANTHROPIC_API_KEY=`.
5. Save the file.

It should look like this (with your real values, no quotes needed):

```
TELEGRAM_BOT_TOKEN=123456789:AAExampleTokenTextGoesHere
ANTHROPIC_API_KEY=sk-ant-api03-exampleKeyTextGoesHere
```

That's it — the bot code never sees these values typed anywhere except in
this one private file.

### 4. Don't have a Telegram bot token yet? Create one

1. Open Telegram and search for **"BotFather"** (the official bot for
   creating bots — verified blue checkmark).
2. Send it `/newbot` and follow the prompts (pick a name and a username
   ending in "bot").
3. BotFather will reply with a token that looks like
   `123456789:AAExampleTokenTextGoesHere`. Copy that into your `.env` file
   as described in Step 3.

### 5. Run the bot

In your terminal, in this folder, run:

```
python3 bot.py
```

You should see a line like `Bot starting (model=claude-opus-4-8)...`. Leave
this terminal window open — the bot only runs while this command is active.

### 6. Message your bot

1. In Telegram, search for the username you gave your bot in Step 4.
2. Open a chat with it and send `/start`.
3. Send it any message — it will forward your message to Claude and reply
   with the answer.

Useful commands inside Telegram:
- `/start` — greet the bot and clear conversation history
- `/reset` — clear conversation history (start a fresh topic)
- `/build <task>` — ask Jarvis to plan and build something (see below)
- `/cancelbuild` — stop a build that's planning or in progress

### 7. Enable /build (optional — lets Jarvis build things for you)

`/build` lets you ask Jarvis to write code or automate something, without
opening Claude Code yourself. It's off by default — only you should be able
to trigger it, since it can run real commands on your machine.

1. In Telegram, message **@userinfobot** — it replies with your numeric user
   ID (not your @username).
2. Open `.env` and paste that number after `JARVIS_OWNER_ID=`.
3. Reinstall dependencies (adds the Claude Agent SDK): `pip install -r requirements.txt`
4. Restart the bot.

Now `/build fix the bug in auth.py` (for example) works like this:
1. **Plan.** Jarvis looks around and replies with what it *intends* to do —
   it cannot write files or run commands yet, that's enforced by the SDK, not
   just a prompt.
2. **You approve or cancel.** Jarvis sends "✅ Build it" / "❌ Cancel" buttons
   in Telegram. Nothing happens until you tap one.
3. **Build.** Only after you approve does it actually create/edit files and
   run commands — inside a dedicated `jarvis-projects/` folder (see below),
   with live status updates in Telegram as it works.
4. **Review.** When it's done, Jarvis lists the files it touched. You review,
   commit, and push yourself — it does not push to GitHub or open pull
   requests on its own.

**Where the code lives:** by default, `jarvis-projects/` is created as a
sibling folder next to this repo (not inside it), so Jarvis can never edit
its own bot code. Override the location with `WORKSPACE_DIR=` in `.env` if
you want it somewhere else.

**Safety limits, built in regardless of what you approve:**
- Only your Telegram user ID can use `/build` or approve a build.
- File writes are blocked outside the `jarvis-projects` workspace.
- `git push`, `gh` (GitHub CLI), `sudo`, and a few other destructive/
  network-risky commands are always blocked, even after approval.

**What this does *not* protect against:** this runs directly on your
machine, not in an isolated container — the command blocklist is a
best-effort guard, not a hard sandbox. Only approve builds you've actually
read the plan for, and consider running the bot on a machine/user account
you're comfortable giving that access to.

### 8. Stopping the bot

Go back to the terminal window and press `Ctrl+C`. To run it again later,
just repeat Step 5 (your `.env` file stays put, so you won't need to
re-enter your keys).

## Notes

- The bot remembers the last ~20 messages per Telegram chat, saved to a file
  called `conversations.db` in this folder — so it still remembers your
  conversation even after you stop and restart the bot. Delete that file (or
  send `/reset` in Telegram) to wipe history and start fresh.
- By default it uses Anthropic's `claude-opus-4-8` model. To use a cheaper/
  faster model instead, add a line like `CLAUDE_MODEL=claude-haiku-4-5` to
  your `.env` file.
- Keep your `.env` file private — anyone with your Anthropic API key can
  spend money on your account, and anyone with your bot token can control
  your bot. `conversations.db` holds your chat history, so treat it as
  private too — it's already excluded from git via `.gitignore`.
