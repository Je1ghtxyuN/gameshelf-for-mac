#!/usr/bin/env python3
"""Publish a verified, signed Sparkle feed for an existing stable GitHub release."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

REPOSITORY = "Je1ghtxyuN/gameshelf-for-mac"
FEED_URL = f"https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml"
SPARKLE_VERSION = "2.10.1"
SPARKLE_SHA256 = "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
SPARKLE_URL = f"https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/Sparkle-{SPARKLE_VERSION}.tar.xz"
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
ROOT = Path(__file__).resolve().parents[1]


class ValidationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def run(args):
    # Never forward tool diagnostics: upstream errors can echo malformed keys.
    env = {k: v for k, v in os.environ.items() if k != "SPARKLE_PRIVATE_KEY"}
    result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env)
    require(result.returncode == 0, f"{Path(args[0]).name} failed (diagnostics suppressed)")
    return result.stdout


def gh_json(endpoint):
    return json.loads(run(["gh", "api", endpoint]))


def decode_key(value):
    try:
        raw = base64.b64decode(value.strip(), validate=True)
    except (ValueError, TypeError):
        raise ValidationError("Invalid base64 key") from None
    require(len(raw) == 32, "Key must decode to 32 bytes (Ed25519 seed/public key)")
    return raw


def validate_config(config):
    require(config.get("feedURL") == FEED_URL, "Unexpected stable feed URL")
    return decode_key(config.get("publicKey", ""))


def validate_seed(seed, public_key):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    derived = Ed25519PrivateKey.from_private_bytes(decode_key(seed)).public_key()
    require(derived.public_bytes(Encoding.Raw, PublicFormat.Raw) == public_key,
            "Signing seed does not match configured public key")


def validate_release(release):
    require(release.get("draft") is False and release.get("prerelease") is False,
            "Only published stable releases are supported")
    require(bool(release.get("published_at")), "Release has not been published")
    tag = release.get("tag_name", "")
    require(re.fullmatch(r"v?[0-9]+(?:\.[0-9]+){1,3}", tag) is not None,
            "Release tag must be a numeric stable version, optionally prefixed by v")
    require(release.get("html_url") == f"https://github.com/{REPOSITORY}/releases/tag/{tag}",
            "Release is not from the expected repository")
    dmgs = [a for a in release.get("assets", []) if a.get("name", "").lower().endswith(".dmg")]
    require(len(dmgs) == 1, "Exactly one DMG is required; multiarchitecture releases are unsupported")
    asset = dmgs[0]
    version = tag.removeprefix("v")
    require(asset.get("name") == f"GameShelf-v{version}-macOS-arm64.dmg",
            "DMG name/version/architecture does not match release")
    expected = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{asset['name']}"
    require(asset.get("browser_download_url") == expected, "Unexpected DMG download source")
    require(asset.get("url") == f"https://api.github.com/repos/{REPOSITORY}/releases/assets/{asset.get('id')}",
            "Unexpected asset API source")
    require(isinstance(asset.get("size"), int) and asset["size"] > 0, "Invalid DMG size")
    require(asset.get("state") == "uploaded", "DMG upload is incomplete")
    require(not any(a.get("name") == "appcast.xml" for a in release["assets"]),
            "appcast.xml already exists; refusing to replace a live feed")
    return version, asset


def validate_bundle(info, config, version, architectures):
    require(info.get("CFBundleIdentifier") == "local.gameshelf.app", "Wrong application bundle")
    require(info.get("CFBundleShortVersionString") == version, "Release/bundle version mismatch")
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", info.get("CFBundleVersion", "")) is not None,
            "Invalid bundle build version")
    require(architectures.split() == ["arm64"], "Only arm64 bundles are supported")
    require(info.get("SUFeedURL") == FEED_URL, "Bundle has wrong feed URL")
    require(info.get("SUPublicEDKey") == config["publicKey"], "Bundle public key mismatch")
    require(info.get("SURequireSignedFeed") is True, "Bundle must require a signed feed")
    require(info.get("SUVerifyUpdateBeforeExtraction") is True, "Bundle must verify before extraction")
    require(bool(info.get("LSMinimumSystemVersion")), "Missing minimum macOS version")


def validate_appcast(path, asset, info, public_key, dmg):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    items = ET.parse(path).getroot().findall("./channel/item")
    require(len(items) == 1, "Feed must contain exactly one stable release")
    item = items[0]
    require(item.findtext(NS + "version") == info["CFBundleVersion"], "Feed build version mismatch")
    require(item.findtext(NS + "shortVersionString") == info["CFBundleShortVersionString"], "Feed version mismatch")
    require(item.findtext(NS + "hardwareRequirements") == "arm64", "Missing arm64 hardware restriction")
    require(item.findtext(NS + "minimumSystemVersion") == info["LSMinimumSystemVersion"], "Feed minimum OS mismatch")
    require(item.find(NS + "channel") is None, "Unexpected prerelease channel")
    enclosures = item.findall("enclosure")
    require(len(enclosures) == 1 and item.find(NS + "deltas") is None, "Unexpected extra downloads")
    enclosure = enclosures[0]
    require(enclosure.get("url") == asset["browser_download_url"], "Feed download source mismatch")
    require(enclosure.get("length") == str(asset["size"]), "Feed download size mismatch")
    try:
        signature = base64.b64decode(enclosure.get(NS + "edSignature", ""), validate=True)
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, dmg.read_bytes())
    except Exception:
        raise ValidationError("DMG signature does not match configured public key") from None


def inspect_dmg(dmg, work, config, version):
    mount = work / "mount"
    mount.mkdir()
    mounted = False
    try:
        run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, dmg])
        mounted = True
        apps = list(mount.glob("*.app"))
        require(len(apps) == 1 and apps[0].name == "GameShelf.app", "DMG must contain GameShelf.app")
        app = apps[0]
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        arch = run(["lipo", "-archs", app / "Contents/MacOS/GameShelf"]).decode().strip()
        validate_bundle(info, config, version, arch)
        bundled_config = json.loads((app / "Contents/Resources/Updates.json").read_text())
        require(validate_config(bundled_config) == validate_config(config), "Bundled update config mismatch")
        run(["codesign", "--verify", "--deep", "--strict", app])
        return info
    finally:
        if mounted:
            run(["hdiutil", "detach", mount])


def sparkle_tools(work, archive):
    if archive is None:
        archive = work / "Sparkle.tar.xz"
        with urllib.request.urlopen(SPARKLE_URL, timeout=120) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == SPARKLE_SHA256,
            "Sparkle distribution checksum mismatch")
    destination = work / "sparkle"
    destination.mkdir()
    with tarfile.open(archive) as tar:
        tar.extractall(destination, filter="data")
    return destination / "bin"


def publish(args):
    require(sys.platform == "darwin", "Publishing requires macOS")
    config = json.loads((ROOT / "Resources/Updates.json").read_text())
    public_key = validate_config(config)
    # Pop the secret before starting any subprocess. Local file is never modified.
    seed = args.key_file.read_text().strip() if args.key_file else os.environ.pop("SPARKLE_PRIVATE_KEY", "").strip()
    validate_seed(seed, public_key)
    require(re.fullmatch(r"v?[0-9]+(?:\.[0-9]+){1,3}", args.tag) is not None, "Invalid release tag")
    endpoint = f"repos/{REPOSITORY}/releases"
    release = gh_json(f"{endpoint}/tags/{args.tag}")
    version, asset = validate_release(release)
    require(release["tag_name"] == args.tag, "Requested/reported release tag mismatch")
    require(gh_json(f"{endpoint}/latest")["id"] == release["id"], "Release is not GitHub's latest stable release")
    with tempfile.TemporaryDirectory(prefix="gameshelf-appcast-") as temporary:
        work = Path(temporary)
        key = work / "private-key.txt"
        with open(key, "x", opener=lambda p, f: os.open(p, f, 0o600)) as output:
            output.write(seed + "\n")
        seed = None
        archives = work / "archives"
        archives.mkdir()
        dmg = archives / asset["name"]
        # gh handles authentication; do not forward tokens to arbitrary asset URLs.
        with dmg.open("wb") as output:
            env = {k: v for k, v in os.environ.items() if k != "SPARKLE_PRIVATE_KEY"}
            result = subprocess.run(["gh", "api", f"{endpoint}/assets/{asset['id']}",
                                     "-H", "Accept: application/octet-stream"], stdout=output,
                                    stderr=subprocess.DEVNULL, env=env)
        require(result.returncode == 0 and dmg.stat().st_size == asset["size"], "DMG download failed or is incomplete")
        digest = asset.get("digest")
        if digest:
            require(digest == "sha256:" + hashlib.sha256(dmg.read_bytes()).hexdigest(), "Asset digest mismatch")
        info = inspect_dmg(dmg, work, config, version)
        tools = sparkle_tools(work, args.sparkle_archive)
        feed = archives / "appcast.xml"
        run([tools / "generate_appcast", "--ed-key-file", key, "--maximum-deltas", "0",
             "--download-url-prefix", asset["browser_download_url"].rsplit("/", 1)[0] + "/",
             "--link", f"https://github.com/{REPOSITORY}", "-o", feed, archives])
        validate_appcast(feed, asset, info, public_key, dmg)
        run([tools / "sign_update", "--ed-key-file", key, feed])
        run([tools / "sign_update", "--verify", "--ed-key-file", key, feed])
        # Read-only validation after signing; never reserialize a signed feed.
        validate_appcast(feed, asset, info, public_key, dmg)
        current = gh_json(f"{endpoint}/tags/{args.tag}")
        _, current_asset = validate_release(current)
        require(current_asset == asset and current["id"] == release["id"], "Release changed during signing")
        require(gh_json(f"{endpoint}/latest")["id"] == release["id"], "Latest stable release changed")
        if args.publish:
            run(["gh", "release", "upload", args.tag, feed, "--repo", REPOSITORY])
            print("Uploaded verified signed appcast.xml")
        else:
            require(not args.output.exists(), "Output already exists")
            shutil.copyfile(feed, args.output)
            print("Wrote verified signed appcast.xml; no release assets changed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--key-file", type=Path, help="Base64 32-byte seed; otherwise SPARKLE_PRIVATE_KEY")
    parser.add_argument("--sparkle-archive", type=Path, help="Cached distribution, checksum always verified")
    parser.add_argument("--publish", action="store_true", help="Upload to release; default writes local preview")
    parser.add_argument("--output", type=Path, default=Path("appcast.xml"))
    args = parser.parse_args()
    os.umask(0o077)
    try:
        publish(args)
    except Exception as error:
        # No tracebacks/tool output/exception values containing private material.
        print(str(error) if isinstance(error, ValidationError) else "Publishing failed; no feed was intentionally published", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
