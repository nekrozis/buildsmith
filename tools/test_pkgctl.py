"""Offline tests for tools/pkgctl.py.

Every test builds a throwaway repository root in a temporary directory and runs
pkgctl as a subprocess with PKGCTL_ROOT pointing at it, so nothing here touches
the real recipes, the network or the developer's git config.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PKGCTL = REPO / "tools" / "pkgctl.py"


def sha256_file(path):
    digest = hashlib.sha256()
    digest.update(Path(path).read_bytes())
    return digest.hexdigest()


class PkgctlTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pkgctl-test-"))
        self.root = self.tmp / "repo"
        (self.root / "packages").mkdir(parents=True)
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.git_env = {
            "GIT_AUTHOR_NAME": "pkgctl tests",
            "GIT_AUTHOR_EMAIL": "tests@example.invalid",
            "GIT_COMMITTER_NAME": "pkgctl tests",
            "GIT_COMMITTER_EMAIL": "tests@example.invalid",
            "GIT_AUTHOR_DATE": "2024-01-02T03:04:05+00:00",
            "GIT_COMMITTER_DATE": "2024-01-02T03:04:05+00:00",
        }

    # -- helpers ---------------------------------------------------------- #

    def git(self, cwd, *args):
        env = dict(os.environ, **self.git_env)
        result = subprocess.run(["git", *args], cwd=str(cwd), env=env, text=True,
                                capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def make_source_repo(self, files=None, tag="v1.0.0", name="upstream"):
        source = self.tmp / name
        source.mkdir(parents=True, exist_ok=True)
        payload = files or {"README.md": "demo\n"}
        for name, content in payload.items():
            (source / name).write_text(content, encoding="utf-8")
        self.git(source, "init", "--quiet", "--initial-branch=main")
        self.git(source, "add", "-A")
        self.git(source, "commit", "--quiet", "-m", "initial")
        self.git(source, "tag", tag)
        return source, self.git(source, "rev-parse", "HEAD")

    def write_recipe(self, name="demo", commit="", source_url="", tag="v${pkgver}",
                     distribution="allowed", ab=True, script=None, sources=None,
                     extra=""):
        directory = self.root / "packages" / name
        directory.mkdir(parents=True, exist_ok=True)
        if sources is None:
            sources = [
                "  - type: git",
                f"    url: {source_url}",
                f"    tag: {tag}",
                f"    commit: {commit}",
                f"    dir: {name}",
            ]
        recipe = textwrap.dedent(
            f"""\
            name: {name}
            summary: test package
            homepage: https://example.invalid/{name}
            license: MIT

            version:
              pkgver: 1.0.0
              pkgrel: 1

            arch: [amd64v3]

            sources:
            """
        )
        recipe += "\n".join(sources) + "\n\n"
        recipe += textwrap.dedent(
            f"""\
            build:
              script: build.sh
              shell: bash
              runner: ubuntu-24.04
              toolchain:
                {{}}
              env:
                DEMO_NAME: {name}

            stage:
              - from: ${{out}}
                to: bin

            smoke: []

            reproducibility:
              level: L2
              ab: {"true" if ab else "false"}
              cross_env: false
              verified_on: [ubuntu-24.04]

            distribution: {distribution}
            """
        )
        recipe += extra
        (directory / "package.yml").write_text(recipe, encoding="utf-8")
        build = directory / "build.sh"
        build.write_text(script or textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            mkdir -p "$PKG_OUT_DIR"
            printf 'payload for %s\\n' "$DEMO_NAME" > "$PKG_OUT_DIR/$DEMO_NAME.txt"
            printf 'epoch %s\\n' "$SOURCE_DATE_EPOCH" > "$PKG_OUT_DIR/epoch.txt"
            """
        ), encoding="utf-8")
        build.chmod(0o755)
        return directory

    def pkgctl(self, *args, expect=0):
        env = dict(os.environ, PKGCTL_ROOT=str(self.root))
        env.update(self.git_env)
        result = subprocess.run([sys.executable, str(PKGCTL), *args], cwd=str(self.root),
                                env=env, text=True, capture_output=True, check=False)
        if expect == 0:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def build_and_package(self, package="demo", build_id="a", out=None):
        work = self.tmp / "work"
        self.pkgctl("build", "--package", package, "--id", build_id, "--work", str(work))
        out_dir = Path(out) if out else self.tmp / "dist" / build_id
        self.pkgctl("package", "--package", package, "--id", build_id,
                    "--out", str(out_dir), "--work", str(work))
        return work, out_dir


class RecipeValidationTest(PkgctlTestCase):
    def test_valid_recipe_passes(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source))
        result = self.pkgctl("validate", "--package", "demo")
        self.assertIn("validated 1 recipe", result.stdout)

    def test_missing_smoke_key_is_reported(self):
        source, commit = self.make_source_repo()
        directory = self.write_recipe(commit=commit, source_url=str(source))
        recipe = directory / "package.yml"
        recipe.write_text(recipe.read_text(encoding="utf-8").replace("smoke: []\n", ""),
                          encoding="utf-8")
        result = self.pkgctl("validate", "--package", "demo", expect=1)
        self.assertIn("smoke", result.stderr)

    def test_unknown_key_is_reported(self):
        source, commit = self.make_source_repo()
        directory = self.write_recipe(commit=commit, source_url=str(source))
        recipe = directory / "package.yml"
        recipe.write_text(recipe.read_text(encoding="utf-8") + "\nmaintainer: nobody\n",
                          encoding="utf-8")
        result = self.pkgctl("validate", "--package", "demo", expect=1)
        self.assertIn("unknown top-level key", result.stderr)

    def test_bash_on_a_windows_runner_is_rejected(self):
        source, commit = self.make_source_repo()
        directory = self.write_recipe(commit=commit, source_url=str(source))
        recipe = directory / "package.yml"
        recipe.write_text(recipe.read_text(encoding="utf-8").replace(
            "runner: ubuntu-24.04", "runner: windows-2025"), encoding="utf-8")
        result = self.pkgctl("validate", "--package", "demo", expect=1)
        self.assertIn("pwsh only", result.stderr)

    def test_script_suffix_must_match_the_shell(self):
        source, commit = self.make_source_repo()
        directory = self.write_recipe(commit=commit, source_url=str(source))
        recipe = directory / "package.yml"
        recipe.write_text(recipe.read_text(encoding="utf-8").replace(
            "script: build.sh", "script: build.ps1"), encoding="utf-8")
        (directory / "build.ps1").write_text("exit 0\n", encoding="utf-8")
        result = self.pkgctl("validate", "--package", "demo", expect=1)
        self.assertIn("must end with .sh", result.stderr)

    def test_arch_is_validated(self):
        source, commit = self.make_source_repo()
        directory = self.write_recipe(commit=commit, source_url=str(source))
        recipe = directory / "package.yml"
        recipe.write_text(recipe.read_text(encoding="utf-8").replace("arch: [amd64v3]", "arch: [x86]"),
                          encoding="utf-8")
        result = self.pkgctl("validate", "--package", "demo", expect=1)
        self.assertIn("unknown arch", result.stderr)

    def test_moved_tag_is_detected(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source))
        (source / "README.md").write_text("second\n", encoding="utf-8")
        self.git(source, "commit", "--quiet", "-am", "second")
        self.git(source, "tag", "-f", "v1.0.0")
        result = self.pkgctl("build", "--package", "demo", "--work", str(self.tmp / "work"), expect=1)
        self.assertIn("now points at", result.stderr)


class PlanTest(PkgctlTestCase):
    def test_placeholders_are_rendered(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source))
        output = self.pkgctl("plan", "--package", "demo").stdout
        plan = json.loads(output)
        self.assertEqual(plan["pkgver"], "1.0.0")
        self.assertEqual(plan["full"], "1.0.0-1")
        self.assertEqual(plan["artifact"], "demo-1.0.0-1-amd64v3.zip")
        self.assertEqual(plan["sources"][0]["url"], str(source))
        self.assertEqual(plan["sources"][0]["tag"], "v1.0.0")
        self.assertTrue(plan["publishable"])

    def test_private_package_is_not_publishable(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source), distribution="private-only")
        plan = json.loads(self.pkgctl("plan", "--package", "demo").stdout)
        self.assertFalse(plan["publishable"])

    def test_ids_follow_reproducibility_flag(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source), ab=True)
        self.assertEqual(json.loads(self.pkgctl("plan", "--package", "demo", "--ids").stdout), ["a", "b"])
        self.write_recipe(commit=commit, source_url=str(source), ab=False)
        self.assertEqual(json.loads(self.pkgctl("plan", "--package", "demo", "--ids").stdout), ["a"])

    def test_override_version_wins(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source))
        plan = json.loads(self.pkgctl("plan", "--package", "demo", "--pkgver", "1.0.0",
                                      "--pkgrel", "3").stdout)
        self.assertEqual(plan["full"], "1.0.0-3")


class PackagingTest(PkgctlTestCase):
    def test_roundtrip_build_package_verify(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source))
        _, out = self.build_and_package()
        archive = out / "demo-1.0.0-1-amd64v3.zip"
        manifest_path = out / "demo-1.0.0-1-amd64v3.manifest.json"
        self.assertTrue(archive.is_file())
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["archive"]["sha256"], sha256_file(archive))
        self.assertEqual(manifest["source_date_epoch"], 1704164645)
        self.assertIn("bin", {entry["path"].split("/")[0] for entry in manifest["files"]})
        self.pkgctl("verify", "--manifest", str(manifest_path))
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(package.namelist()[0].split("/")[0], "demo")
        sums = (out / "SHA256SUMS").read_text(encoding="utf-8")
        self.assertIn("demo-1.0.0-1-amd64v3.zip", sums)

    def test_smoke_runs_a_staged_program_by_absolute_path(self):
        source, commit = self.make_source_repo()
        directory = self.write_recipe(commit=commit, source_url=str(source))
        recipe = directory / "package.yml"
        recipe.write_text(recipe.read_text(encoding="utf-8").replace(
            "smoke: []", "smoke:\n  - [bin/argv0.sh]"), encoding="utf-8")
        (directory / "build.sh").write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "mkdir -p \"$PKG_OUT_DIR\"\n"
            "cat > \"$PKG_OUT_DIR/argv0.sh\" <<'EOS'\n"
            "#!/bin/sh\n"
            "printf '%s\\n' \"$0\"\n"
            "EOS\n"
            "chmod +x \"$PKG_OUT_DIR/argv0.sh\"\n", encoding="utf-8")
        work = self.tmp / "work"
        self.pkgctl("build", "--package", "demo", "--id", "a", "--work", str(work))
        result = self.pkgctl("smoke", "--package", "demo", "--id", "a", "--work", str(work))
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        self.assertTrue(lines, result.stdout)
        self.assertTrue(os.path.isabs(lines[-1]), f"not absolute: {lines[-1]}")
        self.assertEqual(Path(lines[-1]).name, "argv0.sh")

    def test_packaging_is_byte_identical(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source))
        work, out_a = self.build_and_package(build_id="a")
        out_b = self.tmp / "dist" / "again"
        self.pkgctl("package", "--package", "demo", "--id", "a",
                    "--out", str(out_b), "--work", str(work))
        self.assertEqual(sha256_file(out_a / "demo-1.0.0-1-amd64v3.zip"),
                         sha256_file(out_b / "demo-1.0.0-1-amd64v3.zip"))

    def test_verify_rejects_tampered_archive(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source))
        _, out = self.build_and_package()
        archive = out / "demo-1.0.0-1-amd64v3.zip"
        archive.write_bytes(archive.read_bytes() + b"tampered")
        result = self.pkgctl("verify", "--manifest", str(out / "demo-1.0.0-1-amd64v3.manifest.json"),
                             expect=1)
        self.assertIn("digest mismatch", result.stderr)

    def test_manifest_records_script_and_recipe_hashes(self):
        source, commit = self.make_source_repo()
        directory = self.write_recipe(commit=commit, source_url=str(source))
        _, out = self.build_and_package()
        manifest = json.loads((out / "demo-1.0.0-1-amd64v3.manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["build"]["script_sha256"], sha256_file(directory / "build.sh"))
        self.assertEqual(manifest["build"]["recipe_sha256"], sha256_file(directory / "package.yml"))


class AssembleTest(PkgctlTestCase):
    def test_ab_identical_marks_verified(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source))
        for build_id in ("a", "b"):
            self.build_and_package(build_id=build_id)
        dist = self.tmp / "dist"
        self.pkgctl("assemble", "--package", "demo", "--ids", "a,b", "--out", str(dist))
        manifest = json.loads((dist / "demo-1.0.0-1-amd64v3.manifest.json").read_text(encoding="utf-8"))
        self.assertTrue(manifest["reproducibility"]["ab_verified"])
        self.assertEqual(len(manifest["reproducibility"]["ab_sha256"]), 2)
        self.assertTrue((dist / "demo-1.0.0-1-amd64v3.zip").is_file())

    def test_ab_detects_diverging_builds(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source))
        work = self.tmp / "work"
        self.build_and_package(build_id="a")
        self.pkgctl("build", "--package", "demo", "--id", "b", "--work", str(work))
        diverged = work / "b" / "stage" / "demo" / "bin" / "extra.txt"
        diverged.parent.mkdir(parents=True, exist_ok=True)
        diverged.write_text("leak\n", encoding="utf-8")
        self.pkgctl("package", "--package", "demo", "--id", "b",
                    "--out", str(self.tmp / "dist" / "b"), "--work", str(work))
        result = self.pkgctl("assemble", "--package", "demo", "--ids", "a,b",
                             "--out", str(self.tmp / "dist"), expect=1)
        self.assertIn("differ", result.stderr)

    def test_ab_refuses_when_package_disables_it(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source), ab=False)
        for build_id in ("a", "b"):
            self.build_and_package(build_id=build_id)
        result = self.pkgctl("assemble", "--package", "demo", "--ids", "a,b",
                             "--out", str(self.tmp / "dist"), expect=1)
        self.assertIn("reproducibility.ab", result.stderr)


class IndexTest(PkgctlTestCase):
    def make_manifests(self):
        source, commit = self.make_source_repo()
        self.write_recipe(commit=commit, source_url=str(source))
        _, out = self.build_and_package()
        private_source, private_commit = self.make_source_repo(
            {"README.md": "private\n"}, name="upstream-private")
        self.write_recipe(name="secret", commit=private_commit, source_url=str(private_source),
                          distribution="private-only")
        self.pkgctl("build", "--package", "secret", "--id", "a", "--work", str(self.tmp / "work"))
        self.pkgctl("package", "--package", "secret", "--id", "a",
                    "--out", str(self.tmp / "dist" / "a"), "--work", str(self.tmp / "work"))
        return self.tmp / "dist" / "a"

    def test_index_uses_release_urls_and_skips_private(self):
        manifests = self.make_manifests()
        out = self.tmp / "index.json"
        self.pkgctl("index", "--manifests", str(manifests), "--out", str(out),
                    "--repo", "nekrozis/buildsmith", "--verify")
        document = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(list(document["packages"]), ["demo"])
        release = document["packages"]["demo"]["releases"][0]
        self.assertEqual(release["tag"], "demo/v1.0.0-1")
        self.assertEqual(release["url"],
                         "https://github.com/nekrozis/buildsmith/releases/download/"
                         "demo/v1.0.0-1/demo-1.0.0-1-amd64v3.zip")
        self.assertEqual(document["packages"]["demo"]["latest"], "1.0.0-1")

    def test_index_requires_a_location(self):
        manifests = self.make_manifests()
        result = self.pkgctl("index", "--manifests", str(manifests),
                             "--out", str(self.tmp / "index.json"), expect=1)
        self.assertIn("--repo or --base-url", result.stderr)


class WorkflowLintTest(PkgctlTestCase):
    def write_workflow(self, body):
        directory = self.tmp / "workflows"
        directory.mkdir(exist_ok=True)
        (directory / "sample.yml").write_text(body, encoding="utf-8")
        return directory

    def test_pinned_workflow_passes(self):
        directory = self.write_workflow(textwrap.dedent(
            """\
            name: sample
            on: [workflow_dispatch]
            permissions:
              contents: read
            jobs:
              build:
                runs-on: windows-2025
                timeout-minutes: 30
                steps:
                  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
            """
        ))
        self.pkgctl("lint-workflows", "--dir", str(directory))

    def test_floating_runner_and_action_are_rejected(self):
        directory = self.write_workflow(textwrap.dedent(
            """\
            name: sample
            on: [workflow_dispatch]
            jobs:
              build:
                runs-on: windows-latest
                steps:
                  - uses: actions/checkout@v7
            """
        ))
        result = self.pkgctl("lint-workflows", "--dir", str(directory), expect=1)
        self.assertIn("must be pinned", result.stderr)
        self.assertIn("timeout-minutes", result.stderr)

    def test_downloading_artifacts_without_a_name_is_rejected(self):
        # A single unnamed artifact is extracted straight into `path`, so the
        # per-artifact directory the assemble step reads never appears.
        directory = self.write_workflow(textwrap.dedent(
            """\
            name: sample
            on: [workflow_dispatch]
            jobs:
              assemble:
                runs-on: ubuntu-24.04
                timeout-minutes: 30
                steps:
                  - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333
                    with:
                      path: dist
            """
        ))
        result = self.pkgctl("lint-workflows", "--dir", str(directory), expect=1)
        self.assertIn("must pass name", result.stderr)


class RepositoryRecipesTest(unittest.TestCase):
    """Guards the recipes that actually ship in this repository."""

    def test_all_recipes_validate(self):
        env = dict(os.environ)
        result = subprocess.run([sys.executable, str(PKGCTL), "validate", "--all"],
                                cwd=str(REPO), env=env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected = len(list((REPO / "packages").glob("*/package.yml")))
        self.assertGreater(expected, 0)
        self.assertIn(f"validated {expected} recipe", result.stdout)

    def test_repository_workflows_lint(self):
        result = subprocess.run([sys.executable, str(PKGCTL), "lint-workflows"],
                                cwd=str(REPO), text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_every_recipe_pins_a_commit(self):
        for recipe in sorted((REPO / "packages").glob("*/package.yml")):
            text = recipe.read_text(encoding="utf-8")
            self.assertIn("commit:", text, recipe)


if __name__ == "__main__":
    unittest.main(verbosity=2)