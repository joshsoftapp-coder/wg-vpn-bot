#!/usr/bin/env python3
"""
Verify that bot.py's use of python-telegram-bot APIs matches what the
installed version actually exposes.

This catches the class of bug where I call .post_start() but the
ApplicationBuilder for this PTB version doesn't have that method.

Run from repo root:  python3 tests/verify_ptb_api.py
"""
import inspect
import re
import sys
from pathlib import Path


def main() -> int:
    failures = []

    # 1. ApplicationBuilder method existence
    from telegram.ext import ApplicationBuilder

    bot_py = (Path(__file__).resolve().parent.parent
              / "vm" / "bot" / "bot.py").read_text()

    # Find all .method() calls on the ApplicationBuilder chain
    # Pattern: lines that start with '.' inside the builder chain
    builder_section = re.search(
        r"ApplicationBuilder\(\)\s*\n((?:\s*\.\w+\([^)]*\)\s*\n)+)",
        bot_py,
    )
    if not builder_section:
        failures.append("could not find ApplicationBuilder() chain in bot.py")
    else:
        chain = builder_section.group(1)
        methods = re.findall(r"\.(\w+)\(", chain)
        ab = ApplicationBuilder()
        for m in methods:
            if not hasattr(ab, m):
                failures.append(
                    f"ApplicationBuilder has no method '{m}' "
                    f"(bot.py calls it). Available hooks: "
                    f"{[a for a in dir(ab) if a.startswith('post_') or 'init' in a]}"
                )

    # 2. Verify add_error_handler exists
    from telegram.ext import Application
    if not hasattr(Application, "add_error_handler"):
        failures.append("Application has no add_error_handler method")

    # 3. Verify other imports bot.py needs all work and are real classes.
    # We collect references and check they're not None — this exercises
    # the import without pyflakes complaining about unused imports.
    from telegram import InputFile, Update
    from telegram.constants import ParseMode
    from telegram.ext import CommandHandler, MessageHandler, filters
    _required = [InputFile, Update, ParseMode, CommandHandler, MessageHandler, filters]
    for r in _required:
        if r is None:
            failures.append(f"Required import {r} is None")

    # 5. Verify run_polling signature accepts our kwargs
    sig = inspect.signature(Application.run_polling)
    for kw in ("poll_interval", "timeout", "drop_pending_updates"):
        if kw not in sig.parameters:
            failures.append(f"Application.run_polling lacks '{kw}' parameter "
                            f"(have: {list(sig.parameters.keys())})")

    if failures:
        print("FAIL")
        for f in failures:
            print(f"  • {f}")
        return 1

    import telegram
    print(f"OK — python-telegram-bot {telegram.__version__}")
    used_methods = re.findall(r"\.(\w+)\(", builder_section.group(1))
    print(f"  Methods on ApplicationBuilder used by bot.py: {used_methods}")
    print("  All exist on the installed version.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
