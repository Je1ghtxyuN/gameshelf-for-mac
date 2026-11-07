"""Release policy fixtures and signed-feed checks; no network or production keys."""
import base64
import copy
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

SPEC = importlib.util.spec_from_file_location("publish_appcast", Path(__file__).resolve().parents[1] / "Tools/publish_appcast.py")
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


def release_fixture():
    repo = publisher.REPOSITORY
    name = "GameShelf-v1.2.5-macOS-arm64.dmg"
    return {"id": 123, "tag_name": "v1.2.5", "draft": False, "prerelease": False,
            "published_at": "2026-11-07T00:00:00Z",
            "html_url": f"https://github.com/{repo}/releases/tag/v1.2.5",
            "assets": [{"id": 456, "name": name, "size": 7, "state": "uploaded",
                        "url": f"https://api.github.com/repos/{repo}/releases/assets/456",
                        "browser_download_url": f"https://github.com/{repo}/releases/download/v1.2.5/{name}"}]}


class ReleasePolicyTests(unittest.TestCase):
    def test_stable_attached_arm64_dmg(self):
        version, asset = publisher.validate_release(release_fixture())
        self.assertEqual(version, "1.2.5")
        self.assertEqual(asset["id"], 456)

    def test_excludes_prerelease_draft_unpublished_and_suffix(self):
        for change in ({"prerelease": True}, {"draft": True}, {"published_at": None},
                       {"tag_name": "v1.2.5-beta.1"}):
            with self.subTest(change=change), self.assertRaises(publisher.ValidationError):
                publisher.validate_release(release_fixture() | change)

    def test_rejects_release_version_mismatch(self):
        release = release_fixture()
        release["assets"][0]["name"] = "GameShelf-v1.2.4-macOS-arm64.dmg"
        with self.assertRaisesRegex(publisher.ValidationError, "version"):
            publisher.validate_release(release)

    def test_download_source_is_exact_repo_and_tag(self):
        for field, value in (
            ("browser_download_url", "https://evil.example/GameShelf.dmg"),
            ("browser_download_url", release_fixture()["assets"][0]["browser_download_url"].replace("v1.2.5/", "v1.2.4/")),
            ("url", "https://api.github.com/repos/attacker/fork/releases/assets/456"),
        ):
            release = release_fixture()
            release["assets"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(publisher.ValidationError):
                publisher.validate_release(release)

    def test_incomplete_and_multiarch_downloads_rejected(self):
        for kind in ("empty", "multiarch", "intel", "incomplete", "feed_exists"):
            release = release_fixture()
            if kind == "empty":
                release["assets"] = []
            elif kind == "multiarch":
                release["assets"].append(copy.deepcopy(release["assets"][0]))
            elif kind == "intel":
                release["assets"][0]["name"] = "GameShelf-v1.2.5-macOS-x86_64.dmg"
            elif kind == "incomplete":
                release["assets"][0]["state"] = "new"
            else:
                release["assets"].append({"name": "appcast.xml"})
            with self.subTest(kind=kind), self.assertRaises(publisher.ValidationError):
                publisher.validate_release(release)

    def test_config_requires_stable_feed(self):
        for url in ("", publisher.FEED_URL.replace("https:", "http:"), "https://evil.example/appcast.xml"):
            with self.subTest(url=url), self.assertRaises(publisher.ValidationError):
                publisher.validate_config({"feedURL": url, "publicKey": base64.b64encode(bytes(32)).decode()})

    def test_rejects_malformed_key_without_echoing_it(self):
        for key in ("not-a-private-key!", base64.b64encode(bytes(96)).decode()):
            with self.subTest(length=len(key)), self.assertRaises(publisher.ValidationError) as caught:
                publisher.decode_key(key)
            self.assertNotIn(key, str(caught.exception))

    def test_no_upstream_diagnostics_or_secret_in_subprocess(self):
        response = subprocess.CompletedProcess([], 1, stdout=b"private", stderr=b"private")
        with patch.dict(publisher.os.environ, {"SPARKLE_PRIVATE_KEY": "private"}), patch.object(publisher.subprocess, "run", return_value=response) as execute:
            with self.assertRaises(publisher.ValidationError) as caught:
                publisher.run(["sign_update", "--ed-key-file", "/tmp/key"])
        self.assertNotIn("private", str(caught.exception))
        self.assertNotIn("SPARKLE_PRIVATE_KEY", execute.call_args.kwargs["env"])


class SigningTests(unittest.TestCase):
    def setUp(self):
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        self.seed = bytes(range(32))  # public test fixture only, never a production key
        self.key = Ed25519PrivateKey.from_private_bytes(self.seed)
        self.public = self.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.config = {"feedURL": publisher.FEED_URL, "publicKey": base64.b64encode(self.public).decode()}
        self.info = {"CFBundleIdentifier": "local.gameshelf.app", "CFBundleVersion": "41",
                     "CFBundleShortVersionString": "1.2.5", "SUFeedURL": publisher.FEED_URL,
                     "SUPublicEDKey": self.config["publicKey"], "SURequireSignedFeed": True,
                     "SUVerifyUpdateBeforeExtraction": True, "LSMinimumSystemVersion": "15.0"}

    def test_seed_matches_public_config(self):
        publisher.validate_seed(base64.b64encode(self.seed).decode(), self.public)
        with self.assertRaisesRegex(publisher.ValidationError, "match"):
            publisher.validate_seed(base64.b64encode(bytes(32)).decode(), self.public)

    def test_bundle_version_feed_key_signing_and_architecture(self):
        publisher.validate_bundle(self.info, self.config, "1.2.5", "arm64")
        for change in ({"CFBundleShortVersionString": "1.2.4"}, {"SUPublicEDKey": "wrong"},
                       {"SUFeedURL": "https://evil.example"}, {"SURequireSignedFeed": False},
                       {"SUVerifyUpdateBeforeExtraction": False}, {"CFBundleVersion": "beta"}):
            with self.subTest(change=change), self.assertRaises(publisher.ValidationError):
                publisher.validate_bundle(self.info | change, self.config, "1.2.5", "arm64")
        for arch in ("x86_64", "arm64 x86_64"):
            with self.subTest(arch=arch), self.assertRaises(publisher.ValidationError):
                publisher.validate_bundle(self.info, self.config, "1.2.5", arch)

    def feed_fixture(self, directory):
        asset = release_fixture()["assets"][0]
        dmg = directory / asset["name"]
        dmg.write_bytes(b"fixture")
        root = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(root, "channel"), "item")
        for name, value in (("version", "41"), ("shortVersionString", "1.2.5"),
                            ("hardwareRequirements", "arm64"), ("minimumSystemVersion", "15.0")):
            ET.SubElement(item, publisher.NS + name).text = value
        ET.SubElement(item, "enclosure", {"url": asset["browser_download_url"], "length": "7",
                      publisher.NS + "edSignature": base64.b64encode(self.key.sign(dmg.read_bytes())).decode()})
        feed = directory / "appcast.xml"
        ET.ElementTree(root).write(feed, encoding="utf-8", xml_declaration=True)
        return feed, asset, dmg

    def test_feed_rejects_bad_signatures_sources_versions_and_architecture(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            feed, asset, dmg = self.feed_fixture(directory)
            publisher.validate_appcast(feed, asset, self.info, self.public, dmg)
            original = feed.read_bytes()
            for before, after in ((b"41", b"42"), (b"arm64", b"x86_64"),
                                  (b"github.com", b"evil.example"), (b'length="7"', b'length="8"')):
                feed.write_bytes(original.replace(before, after))
                with self.subTest(before=before), self.assertRaises(publisher.ValidationError):
                    publisher.validate_appcast(feed, asset, self.info, self.public, dmg)
            feed.write_bytes(original)
            dmg.write_bytes(b"corrupt")
            with self.assertRaisesRegex(publisher.ValidationError, "signature"):
                publisher.validate_appcast(feed, asset, self.info, self.public, dmg)

    @unittest.skipUnless(sys.platform == "darwin" and (publisher.ROOT / "build/sparkle/distribution/bin/sign_update").exists(),
                         "Optional official Sparkle tool smoke test requires extracted macOS distribution")
    def test_official_tools_sign_and_verify_feed_without_modifying_after_signing(self):
        tool = publisher.ROOT / "build/sparkle/distribution/bin/sign_update"
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            feed, asset, dmg = self.feed_fixture(directory)
            key_file = directory / "key.txt"
            with open(key_file, "x", opener=lambda p, f: publisher.os.open(p, f, 0o600)) as output:
                output.write(base64.b64encode(self.seed).decode() + "\n")
            publisher.run([tool, "--ed-key-file", key_file, feed])
            signed = feed.read_bytes()
            self.assertNotEqual(signed, b"")
            publisher.run([tool, "--verify", "--ed-key-file", key_file, feed])
            publisher.validate_appcast(feed, asset, self.info, self.public, dmg)
            self.assertEqual(feed.read_bytes(), signed)
            feed.write_bytes(signed.replace(b">41<", b">42<"))
            with self.assertRaises(publisher.ValidationError):
                publisher.run([tool, "--verify", "--ed-key-file", key_file, feed])


if __name__ == "__main__":
    unittest.main()
