from __future__ import annotations

import json

from installer import github
from installer.runner import StepContext

from .support import StepCase, sha256

API = "https://api.github.com/repos"


class FailureReasonTest(StepCase):
    def test_rate_limit(self) -> None:
        headers = "HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\nx-ratelimit-reset: 1790000000\r\n"
        reason = github.failure_reason(headers)
        self.assertRegex(reason, r"^rate limit exhausted until \d\d:\d\d ")
        self.assertIn("set GITHUB_TOKEN or run gh auth login", reason)

    def test_status(self) -> None:
        self.assertEqual(github.failure_reason("HTTP/1.1 301\r\n\r\nHTTP/2 404\r\n"), "HTTP 404")

    def test_no_response(self) -> None:
        self.assertEqual(github.failure_reason(""), "no response")


class ApiTest(StepCase):
    def ask(self, repo: str) -> list[str]:
        """The tag latest_tag gives for `repo`, as a list so a failed step leaves it empty."""
        tags: list[str] = []
        self.ok = self.run_action(lambda context: tags.append(github.latest_tag(context, repo)))
        return tags

    def test_latest_tag_compact_and_pretty(self) -> None:
        self.serve(f"{API}/a/compact/releases/latest", '{"id":1,"tag_name":"v1.2.3"}')
        self.serve(f"{API}/a/pretty/releases/latest", '{\n  "tag_name": "v4.5.6"\n}\n')
        self.assertEqual(self.ask("a/compact"), ["v1.2.3"])
        self.assertEqual(self.ask("a/pretty"), ["v4.5.6"])

    def test_latest_tag_with_a_prefix(self) -> None:
        releases = [
            {"tag_name": "cvss/v3.0.0"},
            {"tag_name": "tool/v0.2.0"},
            {"tag_name": "tool/v0.1.0"},
        ]
        self.serve(f"{API}/a/mono/releases?per_page=50", json.dumps(releases))
        self.assertEqual(self.ask("a/mono:tool/"), ["tool/v0.2.0"])

    def test_no_tag_in_the_response(self) -> None:
        self.serve(f"{API}/a/empty/releases/latest", "{}")
        self.assertEqual(self.ask("a/empty"), [])
        self.assertIn("ERROR: No release tag for a/empty in the GitHub API response\n", self.said())

    def test_failure_gives_the_reason(self) -> None:
        self.serve(f"{API}/a/gone/releases/latest.headers", "HTTP/2 404\r\n\r\n")
        self.assertEqual(self.ask("a/gone"), [])
        self.assertIn("ERROR: GitHub API request failed for a/gone (HTTP 404)\n", self.said())

    def test_token_from_the_environment(self) -> None:
        self.serve(f"{API}/a/b/releases/latest", '{"tag_name":"v1"}')
        self.ask("a/b")
        self.assertFalse((self.web / "sent-headers").exists())
        self.env["GITHUB_TOKEN"] = "from-env"
        self.ask("a/b")
        self.assertEqual(
            (self.web / "sent-headers").read_text(), "Authorization: Bearer from-env\n"
        )

    def test_token_from_gh(self) -> None:
        self.fake("gh", "#!/bin/sh\necho from-gh\n")
        self.serve(f"{API}/a/b/releases/latest", '{"tag_name":"v1"}')
        self.ask("a/b")
        self.assertEqual((self.web / "sent-headers").read_text(), "Authorization: Bearer from-gh\n")

    def test_download_verified_against_the_recorded_digest(self) -> None:
        asset = "https://github.com/a/b/releases/download/v1/tool.tar.gz"
        self.serve(asset, b"payload")

        def fetch_it(context: StepContext) -> None:
            github.download_verified(context, "a/b", "v1", "tool.tar.gz", context.tmpdir() / "t")

        def release(digest: str) -> str:
            assets = [
                {
                    "name": "other.tar.gz",
                    "uploader": {"login": "x"},
                    "digest": f"sha256:{'c' * 64}",
                },
                {"name": "tool.tar.gz", "uploader": {"login": "x"}, "digest": digest},
            ]
            return json.dumps({"tag_name": "v1", "assets": assets})

        self.serve(f"{API}/a/b/releases/tags/v1", release(f"sha256:{sha256(b'payload')}"))
        self.assertTrue(self.run_action(fetch_it))

        self.serve(f"{API}/a/b/releases/tags/v1", release(f"sha256:{'d' * 64}"))
        self.assertFalse(self.run_action(fetch_it))
        self.assertIn("ERROR: Checksum mismatch for tool.tar.gz: expected ddd", self.said())

        self.serve(f"{API}/a/b/releases/tags/v1", release(""))
        self.assertFalse(self.run_action(fetch_it))
        self.assertIn(
            "ERROR: No sha256 digest for tool.tar.gz in the a/b v1 release\n", self.said()
        )
