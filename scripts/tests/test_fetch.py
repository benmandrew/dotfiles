from __future__ import annotations

from installer import fetch
from installer.runner import StepContext

from .support import StepCase, sha256

A = "a" * 64
B = "b" * 64


class ManifestTest(StepCase):
    def test_one_line_per_asset(self) -> None:
        manifest = f"{A}  tool.tar.gz.sbom.json\n{B}  tool.tar.gz\n"
        self.assertEqual(fetch.manifest_sha256(manifest, "tool.tar.gz"), B)

    def test_bsd_binary_marker(self) -> None:
        self.assertEqual(fetch.manifest_sha256(f"{A} *tool.tar.gz\n", "tool.tar.gz"), A)

    def test_bare_hash(self) -> None:
        self.assertEqual(fetch.manifest_sha256(f"{A.upper()}\n", "tool.tar.gz"), A)

    def test_no_entry(self) -> None:
        self.assertIsNone(fetch.manifest_sha256(f"{A}  other.tar.gz\n", "tool.tar.gz"))
        self.assertIsNone(fetch.manifest_sha256("not-a-hash  tool.tar.gz\n", "tool.tar.gz"))
        self.assertIsNone(fetch.manifest_sha256("", "tool.tar.gz"))


class DownloadTest(StepCase):
    URL = "https://example.test/release/tool.tar.gz"
    MANIFEST = "https://example.test/release/checksums.txt"

    def fetched(self, context: StepContext) -> None:
        dest = context.tmpdir() / "tool.tar.gz"
        fetch.download_verified(context, self.URL, dest, self.MANIFEST)
        self.assertEqual(dest.read_bytes(), b"payload")

    def test_verified_download(self) -> None:
        self.serve(self.URL, b"payload")
        self.serve(self.MANIFEST, f"{sha256(b'payload')}  tool.tar.gz\n")
        self.assertTrue(self.run_action(self.fetched))
        self.assertEqual(self.said(), "")

    def test_missing_file(self) -> None:
        self.assertFalse(self.run_action(self.fetched))
        self.assertIn(f"ERROR: Download failed: {self.URL}\n", self.said())
        # curl's own message is in the step's output.
        self.assertIn("curl: (22)", self.said())

    def test_missing_manifest(self) -> None:
        self.serve(self.URL, b"payload")
        self.assertFalse(self.run_action(self.fetched))
        said = self.said()
        self.assertIn(f"ERROR: Download failed: {self.MANIFEST}\n", said)
        self.assertIn("ERROR: Could not fetch the checksum manifest for tool.tar.gz\n", said)

    def test_wrong_checksum(self) -> None:
        self.serve(self.URL, b"payload")
        self.serve(self.MANIFEST, f"{A}  tool.tar.gz\n")
        self.assertFalse(self.run_action(self.fetched))
        self.assertIn(
            f"ERROR: Checksum mismatch for tool.tar.gz: expected {A}, got {sha256(b'payload')}\n",
            self.said(),
        )

    def test_manifest_without_the_asset(self) -> None:
        self.serve(self.URL, b"payload")
        self.serve(self.MANIFEST, f"{A}  other.tar.gz\n")
        self.assertFalse(self.run_action(self.fetched))
        self.assertIn(f"ERROR: No sha256 for tool.tar.gz in {self.MANIFEST}\n", self.said())
