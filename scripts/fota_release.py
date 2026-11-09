#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Publishes ROM zips as FotaAgent updates (see unica/mods/fotaagent).

    fota_release.py prepare [zip...]
        [--tag <tag>] [--changelog <file>] [--summary <text>]
        [--repo owner/name | --base-url <url>] [--merge <ota json>]
        [--part-size <bytes>] [--out <dir>]

Without zips, takes from out/ the newest build (highest build_info.txt
timestamp) and every incremental zip to it. The tag defaults to
<version>-<build date>, the changelog to changelog.txt at the repo root.
Reads build_info.txt from each zip (full or incremental) and writes to the
output directory (default out/fota/<tag>):
  dd-<zip name>.xml   OMA download descriptor (size, MD5, changelog)
  <zip>.001 ...       parts, for zips bigger than --part-size
  ota-<device>.json   update manifest read by io.unica.fota.UpdateChecker
  upload.txt          the files to attach to the release, one path per line
Nothing goes to the network.

    fota_release.py upload [--repo owner/name] [--clobber] [out dir]

Without a directory, uses the last one prepare wrote. Attaches the files in upload.txt to the release <tag> (created as a draft if
missing) with Content-Type application/octet-stream: DlAgent only accepts a
package whose Content-Type equals the descriptor <type>, and GitHub serves
each asset with the type given at upload time ("gh release upload" picks it
from the extension, application/zip for a zip). Publish the draft afterwards;
the manifest URL (releases/latest/download/...) only sees published releases.
"""

import argparse
import datetime
import glob
import hashlib
import html
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import urllib.parse
import zipfile

DEFAULT_REPO = "At30c/ShitStockModOrSomething"
# GitHub release assets must be under 2 GiB.
DEFAULT_PART_SIZE = 2000 * 1024 * 1024
PACKAGE_TYPE = "application/octet-stream"
ASSET_NAME = re.compile(r"^[A-Za-z0-9._-]+$")
CHUNK = 8 * 1024 * 1024
SRC_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(SRC_DIR, "out")
FOTA_DIR = os.path.join(OUT_DIR, "fota")
DEFAULT_CHANGELOG = os.path.join(SRC_DIR, "changelog.txt")


def die(msg):
    sys.exit(f"fota_release: {msg}")


def warn(msg):
    print(f"warning: {msg}", file=sys.stderr)


class NotABuild(Exception):
    pass


def read_build_info(path):
    try:
        with zipfile.ZipFile(path) as z:
            text = z.read("build_info.txt").decode()
    except (zipfile.BadZipFile, KeyError, OSError, UnicodeDecodeError) as e:
        raise NotABuild(f"{path}: cannot read build_info.txt ({e})")
    info = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
    for key in ("device", "version", "timestamp", "incremental"):
        if not info.get(key):
            raise NotABuild(f"{path}: build_info.txt has no {key}")
    try:
        info["timestamp"] = int(info["timestamp"])
        info["incremental"] = int(info["incremental"])
    except ValueError:
        raise NotABuild(f"{path}: build_info.txt has a non-numeric timestamp")
    return info


def find_newest_builds():
    """The newest build zips in out/: the full one and the incrementals that
    end on the same build."""
    builds = []
    for path in glob.glob(os.path.join(OUT_DIR, "*.zip")):
        try:
            builds.append((path, read_build_info(path)))
        except NotABuild:
            pass
    if not builds:
        die(f"no ROM zips in {OUT_DIR}; build one or pass the zips")
    newest = max(info["timestamp"] for _, info in builds)
    return sorted((b for b in builds if b[1]["timestamp"] == newest),
                  key=lambda b: b[1]["incremental"])


def is_signed(path):
    """True if the zip ends with the whole-file signature footer that
    RecoverySystem.verifyPackage() looks for (signapk -w)."""
    with open(path, "rb") as f:
        f.seek(-6, os.SEEK_END)
        footer = f.read(6)
    sig_start, magic, comment_size = struct.unpack("<HHH", footer)
    return magic == 0xFFFF and sig_start <= comment_size


def hash_and_split(path, part_size, out_dir):
    """Returns (size, md5, [part names]); parts only when size > part_size."""
    size = os.path.getsize(path)
    md5 = hashlib.md5()
    names = []
    split = size > part_size
    name = os.path.basename(path)
    with open(path, "rb") as src:
        index = 0
        while True:
            out = None
            if split:
                index += 1
                part = f"{name}.{index:03d}"
                names.append(part)
                out = open(os.path.join(out_dir, part), "wb")
            left = part_size if split else size
            try:
                while left > 0:
                    buf = src.read(min(CHUNK, left))
                    if not buf:
                        break
                    md5.update(buf)
                    left -= len(buf)
                    if out:
                        out.write(buf)
            finally:
                if out:
                    out.close()
            if not split or src.tell() >= size:
                break
    return size, md5.hexdigest(), names


def changelog_html(path):
    """A .html file is used as is. Otherwise plain text: "# x" is a bold
    heading, "- x" or "* x" a bullet, a blank line a line break."""
    with open(path, encoding="utf-8") as f:
        text = f.read().strip()
    if path.endswith((".html", ".htm")):
        return text
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            out.append("")
        elif line.startswith("#"):
            out.append(f"<b>{html.escape(line.lstrip('#').strip())}</b>")
        elif line[:2] in ("- ", "* "):
            out.append(f"• {html.escape(line[2:].strip())}")
        else:
            out.append(html.escape(line))
    return "<br>".join(out)


def first_text(changelog):
    for line in re.split(r"<br\s*/?>", changelog):
        if re.fullmatch(r"\s*<(b|h\d)>.*</\1>\s*", line):
            continue  # heading
        line = html.unescape(re.sub(r"<[^>]+>", "", line)).lstrip("• ").strip()
        if line:
            return line
    return None


def xml_text(s):
    return html.escape(s, quote=False)


def write_dd(path, name, size, md5, object_uri, changelog, summary):
    description = changelog.replace("]]>", "]]]]><![CDATA[>")
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"""<?xml version="1.0" encoding="UTF-8"?>
<media xmlns="http://www.openmobilealliance.org/xmlns/dd">
  <DDVersion>1.0</DDVersion>
  <name>{xml_text(name)}</name>
  <vendor>UN1CA</vendor>
  <type>{PACKAGE_TYPE}</type>
  <size>{size}</size>
  <objectURI>{xml_text(object_uri)}</objectURI>
  <installParam>MD5={md5};mrType=MINOR</installParam>
  <description><![CDATA[{description}]]></description>
  <summaryDescription>{xml_text(summary)}</summaryDescription>
  <descriptionType>html</descriptionType>
</media>
""")


def entry_key(entry):
    return (entry["timestamp"], entry.get("base_timestamp"))


def prepare(args):
    if args.zips:
        builds = []
        for path in args.zips:
            try:
                builds.append((path, read_build_info(path)))
            except NotABuild as e:
                die(str(e))
    else:
        builds = find_newest_builds()

    if args.changelog is None and os.path.isfile(DEFAULT_CHANGELOG):
        args.changelog = DEFAULT_CHANGELOG
    if not args.tag:
        info = builds[0][1]
        date = datetime.datetime.fromtimestamp(info["timestamp"], datetime.timezone.utc)
        args.tag = f"{info['version']}-{date:%Y%m%d-%H%M}"
    if not ASSET_NAME.match(args.tag):
        die(f"tag {args.tag!r}: use only [A-Za-z0-9._-]")

    if args.base_url:
        base = args.base_url if args.base_url.endswith("/") else args.base_url + "/"
    else:
        base = (f"https://github.com/{args.repo}/releases/download/"
                f"{urllib.parse.quote(args.tag, safe='')}/")
    out_dir = os.path.abspath(args.out or os.path.join(FOTA_DIR, args.tag))
    os.makedirs(out_dir, exist_ok=True)

    print(f"Release tag: {args.tag}")
    print(f"Changelog: {args.changelog or '(none)'}")
    changelog = changelog_html(args.changelog) if args.changelog else ""

    for path, info in builds:
        name = os.path.basename(path)
        if not ASSET_NAME.match(name):
            die(f"{name}: GitHub renames assets with characters outside "
                "[A-Za-z0-9._-]; rename the zip first")
        if not is_signed(path):
            warn(f"{name}: no whole-file signature, FotaAgent will refuse it "
                 "(RecoverySystem.verifyPackage)")

    devices = {info["device"] for _, info in builds}
    if len(devices) != 1:
        die(f"zips for different devices: {', '.join(sorted(devices))}")
    device = devices.pop()

    manifest = {"device": device, "builds": []}
    if args.merge:
        with open(args.merge, encoding="utf-8") as f:
            old = json.load(f)
        if old.get("device") != device:
            die(f"{args.merge} is for device {old.get('device')}, not {device}")
        manifest["builds"] = old.get("builds", [])

    uploads = []
    for path, info in builds:
        name = os.path.basename(path)
        stem = name[:-4] if name.endswith(".zip") else name
        incremental = info["incremental"] != 0
        print(f"- {name}: {info['version']} ({info['timestamp']})"
              + (f", incremental from {info['incremental']}" if incremental else ""))

        size, md5, parts = hash_and_split(path, args.part_size, out_dir)
        print(f"  {size} bytes, MD5 {md5}"
              + (f", {len(parts)} parts" if parts else ""))

        title = f"UN1CA {info['version']}" + (" (incremental)" if incremental else "")
        dd_name = f"dd-{stem}.xml"
        write_dd(os.path.join(out_dir, dd_name), title, size, md5,
                 base + urllib.parse.quote(name),
                 changelog or html.escape(title),
                 args.summary or first_text(changelog) or title)
        uploads.append(os.path.join(out_dir, dd_name))

        entry = {"version": info["version"], "timestamp": info["timestamp"]}
        if incremental:
            entry["base_timestamp"] = info["incremental"]
        entry["dd"] = base + dd_name
        if parts:
            entry["parts"] = []
            left = size
            for part in parts:
                part_len = min(args.part_size, left)
                left -= part_len
                entry["parts"].append({"url": base + urllib.parse.quote(part),
                                       "size": part_len})
                uploads.append(os.path.join(out_dir, part))
        else:
            uploads.append(os.path.abspath(path))

        manifest["builds"] = [e for e in manifest["builds"]
                              if entry_key(e) != entry_key(entry)]
        manifest["builds"].append(entry)

    # UpdateChecker takes the newest build (incremental first), so entries
    # for older builds are dead weight.
    newest = max(e["timestamp"] for e in manifest["builds"])
    for e in manifest["builds"]:
        if e["timestamp"] != newest:
            warn(f"dropping {e['version']} ({e['timestamp']}): older than {newest}")
    manifest["builds"] = sorted(
        (e for e in manifest["builds"] if e["timestamp"] == newest),
        key=lambda e: e.get("base_timestamp", 0))
    if not any("base_timestamp" not in e for e in manifest["builds"]):
        warn("no full package for the newest build: only devices on the "
             "incremental base builds will be offered the update")

    manifest_name = f"ota-{device}.json"
    with open(os.path.join(out_dir, manifest_name), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
    uploads.append(os.path.join(out_dir, manifest_name))

    with open(os.path.join(out_dir, "upload.txt"), "w", encoding="utf-8") as f:
        f.write(f"tag={args.tag}\n")
        f.writelines(p + "\n" for p in uploads)

    with open(os.path.join(FOTA_DIR, "last"), "w", encoding="utf-8") as f:
        f.write(out_dir + "\n")

    print(f"\nWritten to {out_dir}")
    print("Next: scripts/fota_release.py upload")


def gh(*args, capture=True):
    r = subprocess.run(["gh", *args], capture_output=capture, text=True)
    if r.returncode != 0:
        die(f"gh {' '.join(args)} failed: {(r.stderr or '').strip()}")
    return r.stdout


def find_release(repo, tag):
    # The tags endpoint does not return drafts. --jq prints one compact JSON
    # object per line (older gh has no --slurp).
    out = gh("api", "--paginate", f"repos/{repo}/releases?per_page=100",
             "--jq", f".[] | select(.tag_name == {json.dumps(tag)})")
    for line in out.splitlines():
        if line.strip():
            return json.loads(line)
    return None


def upload(args):
    if not args.dir:
        try:
            with open(os.path.join(FOTA_DIR, "last"), encoding="utf-8") as f:
                args.dir = f.read().strip()
        except OSError:
            die("nothing prepared yet; run prepare first")
    print(f"Uploading {args.dir}")
    with open(os.path.join(args.dir, "upload.txt"), encoding="utf-8") as f:
        lines = [line.rstrip("\n") for line in f if line.strip()]
    if not lines or not lines[0].startswith("tag="):
        die("upload.txt has no tag line; run prepare again")
    tag, files = lines[0][4:], lines[1:]
    for path in files:
        if not os.path.isfile(path):
            die(f"missing file: {path}")
    if shutil.which("curl") is None:
        die("curl not found")

    rel = find_release(args.repo, tag)
    if rel is None:
        print(f"- Creating draft release {tag}")
        # The API returns the new release; listing it right away can miss it
        # for a few seconds.
        rel = json.loads(gh("api", "-X", "POST", f"repos/{args.repo}/releases",
                            "-f", f"tag_name={tag}", "-f", f"name={tag}",
                            "-f", "body=", "-F", "draft=true"))
    assets = {a["name"]: a for a in rel["assets"]}
    token = gh("auth", "token").strip()
    upload_url = rel["upload_url"].split("{")[0]

    for path in files:
        name = os.path.basename(path)
        size = os.path.getsize(path)
        old = assets.get(name)
        if old:
            if not args.clobber and old["size"] == size and old["content_type"] == PACKAGE_TYPE:
                print(f"- {name}: already uploaded")
                continue
            if not args.clobber:
                die(f"{name} already exists with another size or type; "
                    "use --clobber to replace it")
            gh("api", "-X", "DELETE", f"repos/{args.repo}/releases/assets/{old['id']}")
        print(f"- Uploading {name} ({size} bytes)")
        r = subprocess.run(
            ["curl", "--fail-with-body", "-sS", "-X", "POST",
             "-H", f"Authorization: Bearer {token}",
             "-H", f"Content-Type: {PACKAGE_TYPE}",
             "-H", "Accept: application/vnd.github+json",
             "-T", path, f"{upload_url}?name={urllib.parse.quote(name)}"],
            capture_output=True, text=True)
        if r.returncode != 0:
            die(f"upload of {name} failed: {r.stdout.strip()} {r.stderr.strip()}")
        asset = json.loads(r.stdout)
        if asset.get("name") != name or asset.get("content_type") != PACKAGE_TYPE:
            die(f"{name} uploaded as {asset.get('name')} ({asset.get('content_type')})")

    state = "draft" if rel.get("draft") else "published"
    print(f"\nRelease {tag} ({state}): {rel['html_url']}")
    if rel.get("draft"):
        print(f"Publish it with: gh release edit {tag} -R {args.repo} --draft=false --latest")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    pp = sub.add_parser("prepare", help="write descriptors, parts and manifest")
    pp.add_argument("--tag", help="release tag (default: <version>-<build date>)")
    pp.add_argument("--repo", default=DEFAULT_REPO)
    pp.add_argument("--base-url", help="host the files somewhere else than the "
                    "GitHub release (URL of the directory holding them)")
    pp.add_argument("--changelog", help="changelog file, .html or plain text "
                    "(default: changelog.txt at the repo root, if present)")
    pp.add_argument("--summary", help="one-line summary (default: first changelog line)")
    pp.add_argument("--merge", help="existing ota-<device>.json to keep entries from")
    pp.add_argument("--part-size", type=int, default=DEFAULT_PART_SIZE)
    pp.add_argument("--out", help="output directory (default out/fota/<tag>)")
    pp.add_argument("zips", nargs="*", help="default: the newest build in out/")
    pp.set_defaults(func=prepare)

    up = sub.add_parser("upload", help="attach the prepared files to the release")
    up.add_argument("--repo", default=DEFAULT_REPO)
    up.add_argument("--clobber", action="store_true", help="replace existing assets")
    up.add_argument("dir", nargs="?", help="default: the last prepared directory")
    up.set_defaults(func=upload)

    args = p.parse_args()
    if args.cmd == "prepare" and args.part_size <= 0:
        die("--part-size must be positive")
    args.func(args)


if __name__ == "__main__":
    main()
