"""Exercise release integrity, stale builds, and partial upload recovery offline."""
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from package_preview import checksum, PLATFORMS
from publish_preview import publish, validate_packages


class PreviewPublishingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.commit = "a" * 40
        self.environment = {
            "GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "push",
            "GITHUB_REPOSITORY": "example/paint", "GITHUB_SHA": self.commit,
            "GITHUB_RUN_ID": "123", "GITHUB_RUN_NUMBER": "7",
        }
        for platform in PLATFORMS:
            archive = self.folder / f"SumiPaint-{platform}-Preview.zip"
            archive.write_bytes(b"preview archive fixture")
            metadata = {
                "platform": platform, "archive": archive.name, "sha256": checksum(archive),
                "commit": self.commit, "workflow_run": "123", "version": "0.1.0", "build_number": "7",
            }
            (self.folder / f"{platform}-build.json").write_text(json.dumps(metadata))
        for name in ("iPhone.png", "iPad.png"):
            (self.folder / name).write_bytes(b"\x89PNG\r\n\x1a\nfixture")

    def run_publish(self, handler):
        with patch.dict(os.environ, self.environment, clear=True), patch("publish_preview.gh", side_effect=handler):
            publish(self.folder)

    def test_corrupted_archive_is_never_published(self):
        (self.folder / "SumiPaint-macOS-Preview.zip").write_bytes(b"changed after packaging")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.run_publish(lambda *args: self.fail("GitHub must not be contacted for a corrupt preview"))

    def test_different_commit_or_run_is_rejected(self):
        for commit, run in (("b" * 40, "123"), (self.commit, "456")):
            with self.subTest(commit=commit, run=run), self.assertRaisesRegex(ValueError, "does not match"):
                validate_packages(self.folder, commit, run)

    def test_missing_device_screenshot_is_rejected(self):
        (self.folder / "iPad.png").unlink()
        with self.assertRaises(FileNotFoundError):
            self.run_publish(lambda *args: self.fail("A partial preview must not be published"))

    def test_pull_request_cannot_publish(self):
        self.environment["GITHUB_EVENT_NAME"] = "pull_request"
        with self.assertRaisesRegex(ValueError, "Only a main"):
            self.run_publish(lambda *args: self.fail("PRs cannot use release permissions"))

    def test_superseded_main_build_is_not_published(self):
        calls = []
        def handler(*args):
            calls.append(args)
            return "b" * 40
        self.run_publish(handler)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "api")
        self.assertFalse((self.folder / "manifest.json").exists())

    def test_finished_release_is_not_modified_on_retry(self):
        names = [f"SumiPaint-{platform}-Preview.zip" for platform in PLATFORMS]
        names += ["manifest.json", "SHA256SUMS", "iPhone.png", "iPad.png"]
        release = {"tag_name": "preview-123", "target_commitish": self.commit, "draft": False,
                   "assets": [{"name": name} for name in names], "html_url": "https://example.invalid/release"}
        def handler(*args):
            if args[0] != "api":
                self.fail("A published preview must remain unchanged")
            return json.dumps([[release]]) if args[1].endswith("/releases") else self.commit
        self.run_publish(handler)

    def test_failed_upload_does_not_publish_the_draft(self):
        calls = []
        def handler(*args):
            calls.append(args)
            if args[0] == "api":
                return "[[]]" if args[1].endswith("/releases") else self.commit
            if args[:2] == ("release", "create"):
                self.assertIn("--draft", args)
                raise RuntimeError("Upload failed after creating a draft")
            self.fail("A failed upload must not publish the draft")
        with self.assertRaisesRegex(RuntimeError, "Upload failed"):
            self.run_publish(handler)
        self.assertEqual(calls[-1][:2], ("release", "create"))

    def test_incomplete_draft_can_be_completed_on_retry(self):
        calls = []
        release = {"tag_name": "preview-123", "target_commitish": self.commit, "draft": True, "assets": []}
        def handler(*args):
            calls.append(args)
            if args[0] == "api":
                return json.dumps([[release]]) if args[1].endswith("/releases") else self.commit
            return ""
        self.run_publish(handler)
        mutations = [args for args in calls if args[0] == "release"]
        self.assertEqual(mutations[0][:2], ("release", "upload"))
        self.assertIn("--clobber", mutations[0])
        self.assertIn("--draft=false", mutations[-1])
        for line in (self.folder / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ")
            self.assertEqual(digest, checksum(self.folder / name))


if __name__ == "__main__":
    unittest.main()
