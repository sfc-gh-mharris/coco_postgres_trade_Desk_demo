#!/usr/bin/env python3
"""Render {{VAR}} templates with values from build/vars.env.

Usage: render.py <vars.env> <src> <dst>
Only {{UPPER_CASE}} tokens are replaced. Tokens with a colon (for example
{{SECRET_PASSWORD:desk_app}}) are left for the in-container SQL runner. Fails if a token
has no value, so a half-rendered file can never be deployed.
"""
import re
import sys

TOKEN = re.compile(r"\{\{([A-Z][A-Z0-9_]*)\}\}")


def load(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v
    return out


def main():
    env_path, src, dst = sys.argv[1:4]
    values = load(env_path)
    text = open(src).read()
    missing = sorted({m for m in TOKEN.findall(text) if m not in values})
    if missing:
        sys.exit(f"render: {src}: no value for {', '.join(missing)}")
    with open(dst, "w") as f:
        f.write(TOKEN.sub(lambda m: values[m.group(1)], text))


if __name__ == "__main__":
    main()
