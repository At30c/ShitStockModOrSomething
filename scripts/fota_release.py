#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Publishes ROM zips as FotaAgent updates (see unica/mods/fotaagent).

    fota_release.py prepare [zip...]
        [--tag <tag>] [--changelog <file>] [--summary <text>]
        [--repo owner/name | --base-url <url>] [--merge <ota json>]
        [--part-size <bytes>] [--out <dir>]
        [--no-upload] [--clobber] [--keep] [--publish]

Without zips, takes from out/ the newest build (highest build_info.txt
timestamp) and every incremental zip to it. The tag defaults to
<version>-<build date>, the changelog to changelog.txt at the repo root.
Reads build_info.txt from each zip (full or incremental) and writes to the
output directory (default out/fota/<tag>):
  dd-<zip name>.xml   OMA download descriptor (size, MD5, changelog)
  <zip>.001 ...       parts, for zips bigger than --part-size
  ota-<device>.json   update manifest read by io.unica.fota.UpdateChecker
  upload.txt          the files to attach to the release, one path per line
  checksums.txt       SHA-256 and size of each of those files
Then it runs upload on that directory (not with --base-url or --no-upload).

    fota_release.py upload [--repo owner/name] [--clobber] [--keep]
        [--publish] [out dir]

Without a directory, uses the last one prepare wrote. Needs gh logged in
(gh auth login). Attaches the files in upload.txt to the release <tag>
(created as a draft if missing) with Content-Type application/octet-stream:
DlAgent only accepts a package whose Content-Type equals the descriptor
<type>, and GitHub serves each asset with the type given at upload time.

Each file is checked against checksums.txt before it is sent, and the asset
is accepted only if GitHub's own SHA-256 digest and size match; otherwise the
asset is deleted and the run stops. Verified files are then removed locally
(keep them with --keep); a later run recognises them on the release by their
digest. The gh token reaches curl through stdin, never the command line, and
only over HTTPS to uploads.github.com without redirects.

The release stays a draft unless --publish is given: the manifest URL
(releases/latest/download/...) only sees published releases, so publishing
is what offers the update to devices.
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
    if not args.base_url and not args.no_upload:
        check_gh()
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
        # Always list parts, a single one for an unsplit zip: UpdateChecker
        # then serves the package through PartProxy on 127.0.0.1, which
        # follows redirects itself. The stock DlAgent pins the Host header of
        # the first URL across the 302 of a GitHub release link, and the
        # asset CDN answers that with 500 (fixed by FotaAgent patch 0020,
        # but builds without it still need the proxy).
        entry["parts"] = []
        if parts:
            left = size
            for part in parts:
                part_len = min(args.part_size, left)
                left -= part_len
                entry["parts"].append({"url": base + urllib.parse.quote(part),
                                       "size": part_len})
                uploads.append(os.path.join(out_dir, part))
        else:
            entry["parts"].append({"url": base + urllib.parse.quote(name),
                                   "size": size})
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

    print("- Recording SHA-256 checksums")
    write_checksums(os.path.join(out_dir, "checksums.txt"),
                    {os.path.basename(p): (sha256_file(p), os.path.getsize(p))
                     for p in uploads})

    with open(os.path.join(FOTA_DIR, "last"), "w", encoding="utf-8") as f:
        f.write(out_dir + "\n")

    print(f"\nWritten to {out_dir}")
    if args.base_url or args.no_upload:
        print("Next: scripts/fota_release.py upload")
        return
    args.dir = out_dir
    upload(args)


def gh(*args, capture=True):
    r = subprocess.run(["gh", *args], capture_output=capture, text=True)
    if r.returncode != 0:
        die(f"gh {' '.join(args)} failed: {(r.stderr or '').strip()}")
    return r.stdout


def check_gh():
    if shutil.which("gh") is None:
        die("gh not found")
    if subprocess.run(["gh", "auth", "status", "--hostname", "github.com"],
                      capture_output=True).returncode != 0:
        die("gh is not logged in to github.com; run: gh auth login")
    if shutil.which("curl") is None:
        die("curl not found")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            block = f.read(CHUNK)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def read_checksums(path):
    sums = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) == 3 and re.fullmatch(r"[0-9a-f]{64}", parts[0]):
                    sums[parts[2]] = (parts[0], int(parts[1]))
    return sums


def write_checksums(path, sums):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for name in sorted(sums):
            f.write(f"{sums[name][0]} {sums[name][1]} {name}\n")
    os.replace(tmp, path)


def asset_matches(asset, sha256, size):
    return (asset.get("state") == "uploaded"
            and asset.get("size") == size
            and asset.get("content_type") == PACKAGE_TYPE
            and asset.get("digest") == f"sha256:{sha256}")


def find_release(repo, tag):
    # The tags endpoint does not return drafts. --jq prints one compact JSON
    # object per line (older gh has no --slurp).
    out = gh("api", "--paginate", f"repos/{repo}/releases?per_page=100",
             "--jq", f".[] | select(.tag_name == {json.dumps(tag)})")
    for line in out.splitlines():
        if line.strip():
            return json.loads(line)
    return None


def curl_upload(token, url, path):
    # The token goes through stdin as curl config, never through argv, so it
    # is not visible in ps or /proc/<pid>/cmdline. HTTPS only, TLS >= 1.2,
    # no redirects (a redirect could carry the header elsewhere).
    config = (f'header = "Authorization: Bearer {token}"\n'
              f'header = "Content-Type: {PACKAGE_TYPE}"\n'
              'header = "Accept: application/vnd.github+json"\n'
              'header = "X-GitHub-Api-Version: 2022-11-28"\n')
    return subprocess.run(
        ["curl", "--config", "-", "--fail-with-body", "-sS",
         "--proto", "=https", "--tlsv1.2", "--max-redirs", "0",
         "-X", "POST", "-T", path, url],
        input=config, capture_output=True, text=True)


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
    check_gh()

    # Checksums recorded by prepare; files without one are hashed now, before
    # anything is sent, so a file changed afterwards is caught.
    sums_path = os.path.join(args.dir, "checksums.txt")
    sums = read_checksums(sums_path)
    for path in files:
        name = os.path.basename(path)
        if not ASSET_NAME.match(name):
            die(f"unexpected asset name: {name}")
        if os.path.isfile(path):
            size = os.path.getsize(path)
            if name not in sums:
                print(f"- Hashing {name}")
                sums[name] = (sha256_file(path), size)
                write_checksums(sums_path, sums)
            elif sums[name][1] != size:
                die(f"{name}: size differs from checksums.txt; run prepare again")
        elif name not in sums:
            die(f"missing file: {path}")

    rel = find_release(args.repo, tag)
    if rel is None:
        print(f"- Creating draft release {tag}")
        # The API returns the new release; listing it right away can miss it
        # for a few seconds.
        rel = json.loads(gh("api", "-X", "POST", f"repos/{args.repo}/releases",
                            "-f", f"tag_name={tag}", "-f", f"name={tag}",
                            "-f", "body=", "-F", "draft=true"))
    assets = {a["name"]: a for a in rel["assets"]}
    upload_url = rel["upload_url"].split("{")[0]
    if not upload_url.startswith("https://uploads.github.com/"):
        die(f"unexpected upload URL: {upload_url}")
    token = gh("auth", "token").strip()
    if not re.fullmatch(r"[A-Za-z0-9_]+", token):
        die("unexpected token format from gh auth token")

    for path in files:
        name = os.path.basename(path)
        sha256, size = sums[name]
        old = assets.get(name)
        if old and asset_matches(old, sha256, size) and not args.clobber:
            print(f"- {name}: already uploaded, SHA-256 verified")
        elif not os.path.isfile(path):
            die(f"{name}: deleted locally but the release has no verified copy; "
                "run prepare again")
        else:
            if sha256_file(path) != sha256:
                die(f"{name}: content changed since it was hashed; run prepare again")
            if old:
                if not args.clobber and old.get("state") == "uploaded":
                    die(f"{name} already exists with another content; "
                        "use --clobber to replace it")
                # A failed or mismatching earlier attempt.
                gh("api", "-X", "DELETE", f"repos/{args.repo}/releases/assets/{old['id']}")
            print(f"- Uploading {name} ({size} bytes)")
            r = curl_upload(token, f"{upload_url}?name={urllib.parse.quote(name)}", path)
            if r.returncode != 0:
                die(f"upload of {name} failed: {r.stdout.strip()} {r.stderr.strip()}")
            asset = json.loads(r.stdout)
            if asset.get("name") != name or not asset_matches(asset, sha256, size):
                if asset.get("id"):
                    gh("api", "-X", "DELETE",
                       f"repos/{args.repo}/releases/assets/{asset['id']}")
                die(f"{name}: GitHub reports {asset.get('digest')} / "
                    f"{asset.get('size')} bytes, expected sha256:{sha256} / {size}; "
                    "the asset was removed")
            print(f"  SHA-256 verified on GitHub: {sha256}")
        if not args.keep and os.path.isfile(path):
            os.remove(path)
            print(f"  removed local {name}")

    if args.publish and rel.get("draft"):
        print(f"- Publishing {tag}")
        gh("release", "edit", tag, "-R", args.repo, "--draft=false", "--latest")
        # Publishing moves the release from its untagged draft URL to the tag.
        rel = find_release(args.repo, tag) or dict(rel, draft=False)
    state = "draft" if rel.get("draft") else "published"
    print(f"\nRelease {tag} ({state}): {rel['html_url']}")
    if rel.get("draft"):
        print(f"Publish it with: scripts/fota_release.py upload --publish {args.dir}")


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
    pp.add_argument("--no-upload", action="store_true",
                    help="only write the files; do not upload them")
    pp.add_argument("--clobber", action="store_true", help="replace existing assets")
    pp.add_argument("--keep", action="store_true",
                    help="keep the local files after a verified upload")
    pp.add_argument("--publish", action="store_true",
                    help="publish the release after the upload (devices see it)")
    pp.add_argument("zips", nargs="*", help="default: the newest build in out/")
    pp.set_defaults(func=prepare)

    up = sub.add_parser("upload", help="attach the prepared files to the release")
    up.add_argument("--repo", default=DEFAULT_REPO)
    up.add_argument("--clobber", action="store_true", help="replace existing assets")
    up.add_argument("--keep", action="store_true",
                    help="keep the local files after a verified upload")
    up.add_argument("--publish", action="store_true",
                    help="publish the release after the upload (devices see it)")
    up.add_argument("dir", nargs="?", help="default: the last prepared directory")
    up.set_defaults(func=upload)

    args = p.parse_args()
    if args.cmd == "prepare" and args.part_size <= 0:
        die("--part-size must be positive")
    args.func(args)


if __name__ == "__main__":
    main()
