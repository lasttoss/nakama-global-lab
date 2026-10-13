#!/usr/bin/env python3
"""Kiểm tra mọi link tương đối trong README.md và docs/*.md có tồn tại thật."""
import os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bad, checked = [], 0
targets = [os.path.join(root, "README.md")]
for dirpath, _, files in os.walk(os.path.join(root, "docs")):
    targets += [os.path.join(dirpath, f) for f in files if f.endswith(".md")]
for path in targets:
    if not os.path.exists(path):
        continue
    base = os.path.dirname(path)
    for m in re.finditer(r'\[[^\]]*\]\(([^)]+)\)', open(path, encoding='utf-8').read()):
        link = m.group(1).split('#')[0].strip()
        if not link or '://' in link or link.startswith('mailto:'):
            continue
        checked += 1
        if not os.path.exists(os.path.normpath(os.path.join(base, link))):
            bad.append(f"{os.path.relpath(path, root)} -> {link}")
if bad:
    print("BROKEN LINKS:"); [print("  " + b) for b in bad]; sys.exit(1)
print(f"OK: {checked} relative links resolve")
