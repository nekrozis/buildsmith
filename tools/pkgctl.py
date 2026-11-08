#!/usr/bin/env python3
"""buildsmith package tool.

Single entry point for recipe validation, source materialisation, building,
deterministic packaging, A/B comparison and index generation.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import zipfile
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: python -m pip install -r tools/requirements.txt")

SCHEMA = 1
ARCHES = ("amd64v3", "amd64", "arm64")
SHELLS = ("bash", "pwsh")
SCRIPT_SUFFIX = {"pwsh": ".ps1", "bash": ".sh"}
DISTRIBUTIONS = ("allowed", "private-only")
LEVELS = ("L0", "L1", "L2", "L3")
ZIP_EPOCH_MIN = 315532800  # 1980-01-01T00:00:00Z, the earliest ZIP timestamp

PLACEHOLDER = re.compile(r"\$\{([a-z0-9_]+)\}")
NAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")
PKGVER_RE = re.compile(r"^[0-9][0-9A-Za-z.+]*$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
USES_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$")

TOP_KEYS = {
    "name",
    "summary",
    "homepage",
    "license",
    "version",
    "arch",
    "sources",
    "build",
    "stage",
    "smoke",
    "reproducibility",
    "distribution",
    "notes",
    "depends",
    "provides",
    "conflicts",
}
BUILD_KEYS = {"script", "shell", "runner", "toolchain", "env", "overrides", "source_date_epoch"}


class Fail(Exception):
    pass


def log(message):
    print(f"pkgctl: {message}", file=sys.stderr, flush=True)


def repo_root(start=None):
    override = os.environ.get("PKGCTL_ROOT")
    if override:
        return Path(override).resolve()
    here = Path(start or __file__).resolve()
    for candidate in [here, *here.parents]:
        if (candidate / "packages").is_dir() and (candidate / "tools").is_dir():
            return candidate
    raise Fail("cannot locate repository root (no packages/ + tools/ ancestor)")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def render(value, variables):
    if not isinstance(value, str):
        return value

    def substitute(match):
        key = match.group(1)
        if key not in variables:
            raise Fail(f"unknown placeholder ${{{key}}} in {value!r}")
        return str(variables[key])

    return PLACEHOLDER.sub(substitute, value)


def natural_key(text):
    return [int(part) if part.isdigit() else part for part in re.split(r"([0-9]+)", str(text))]


def stable_json(data):
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(stable_json(data), encoding="utf-8", newline="\n")


def run(cmd, cwd=None, env=None, capture=False):
    printable = " ".join(str(part) for part in cmd)
    log(printable)
    result = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        check=False,
        text=True,
        capture_output=capture,
    )
    if result.returncode != 0:
        if capture:
            sys.stderr.write(result.stdout or "")
            sys.stderr.write(result.stderr or "")
        raise Fail(f"command failed ({result.returncode}): {printable}")
    return result


def git(args, capture=False):
    return run(["git", *args], capture=capture)


class Recipe:
    def __init__(self, path, data):
        self.path = path
        self.dir = path.parent
        self.data = data

    @staticmethod
    def load(path):
        path = Path(path)
        with open(path, encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
        if not isinstance(data, dict):
            raise Fail(f"{path}: recipe must be a mapping")
        return Recipe(path, data)

    def __getitem__(self, key):
        return self.data[key]

    def get(self, key, default=None):
        return self.data.get(key, default)

    def variables(self, pkgver=None, pkgrel=None, arch=None):
        version = self.data["version"]
        return {
            "name": self.data["name"],
            "pkgver": str(pkgver or version["pkgver"]),
            "pkgrel": int(pkgrel or version["pkgrel"]),
            "arch": arch or self.data["arch"][0],
        }

    def resolved(self, pkgver=None, pkgrel=None, arch=None):
        variables = self.variables(pkgver, pkgrel, arch)
        full = f"{variables['pkgver']}-{variables['pkgrel']}"
        return {
            **variables,
            "full": full,
            "artifact": f"{variables['name']}-{full}-{variables['arch']}.zip",
        }


def validate_recipe(recipe):
    data = recipe.data
    where = str(recipe.path)
    problems = []

    def check(condition, message):
        if not condition:
            problems.append(message)

    for key in data:
        if key not in TOP_KEYS:
            problems.append(f"unknown top-level key {key!r}")
    for key in sorted(TOP_KEYS - {"notes", "depends", "provides", "conflicts"}):
        if key not in data:
            problems.append(f"missing required key {key!r}")
    if problems:
        raise Fail(f"{where}: " + "; ".join(problems))

    check(bool(NAME_RE.match(data["name"])), f"invalid package name {data['name']!r}")

    version = data["version"]
    check(isinstance(version, dict), "version must be a mapping")
    if isinstance(version, dict):
        check("pkgver" in version, "version.pkgver is required")
        check("pkgrel" in version, "version.pkgrel is required")
        check(
            isinstance(version.get("pkgver"), str) and bool(PKGVER_RE.match(version.get("pkgver", ""))),
            f"version.pkgver {version.get('pkgver')!r} must be a string without a leading 'v'",
        )
        check(
            isinstance(version.get("pkgrel"), int) and version.get("pkgrel", 0) >= 1,
            "version.pkgrel must be an integer >= 1",
        )

    arch = data["arch"]
    check(isinstance(arch, list) and bool(arch), "arch must be a non-empty list")
    if isinstance(arch, list):
        for item in arch:
            check(item in ARCHES, f"unknown arch {item!r} (expected one of {', '.join(ARCHES)})")

    sources = data["sources"]
    check(isinstance(sources, list) and bool(sources), "sources must be a non-empty list")
    seen_dirs = set()
    if isinstance(sources, list):
        for index, source in enumerate(sources):
            prefix = f"sources[{index}]"
            if not isinstance(source, dict):
                problems.append(f"{prefix} must be a mapping")
                continue
            kind = source.get("type")
            check(kind in ("git", "url"), f"{prefix}.type must be 'git' or 'url'")
            check(bool(source.get("url")), f"{prefix}.url is required")
            directory = source.get("dir")
            check(bool(directory), f"{prefix}.dir is required")
            if directory:
                check("/" not in directory and ".." not in directory, f"{prefix}.dir must be a plain name")
                check(directory not in seen_dirs, f"{prefix}.dir {directory!r} is duplicated")
                seen_dirs.add(directory)
            if kind == "git":
                check("commit" in source, f"{prefix}.commit is required for git sources")
                check(bool(COMMIT_RE.match(str(source.get("commit", "")))),
                      f"{prefix}.commit must be a full 40-hex SHA")
            elif kind == "url":
                check(bool(SHA256_RE.match(str(source.get("sha256", "")))),
                      f"{prefix}.sha256 must be a sha256 hex digest")
                check(source.get("extract") in ("zip", "tar.gz", "tar.xz", "tar"),
                      f"{prefix}.extract must be one of zip, tar.gz, tar.xz, tar")

    build = data["build"]
    check(isinstance(build, dict), "build must be a mapping")
    if isinstance(build, dict):
        for key in build:
            check(key in BUILD_KEYS, f"unknown build key {key!r}")
        script = build.get("script")
        check(bool(script), "build.script is required")
        if script:
            check((recipe.dir / script).is_file(), f"build.script {script!r} does not exist next to the recipe")
        shell = build.get("shell")
        runner = build.get("runner")
        check(shell in SHELLS, f"build.shell must be one of {', '.join(SHELLS)}")
        if script and shell in SHELLS:
            suffix = SCRIPT_SUFFIX[shell]
            check(script.endswith(suffix), f"build.script must end with {suffix} for shell {shell!r}")
        check(bool(runner), "build.runner is required")
        if isinstance(runner, str) and runner.startswith("windows"):
            check(shell == "pwsh", f"windows runners build with pwsh only (runner {runner!r})")
        toolchain = build.get("toolchain")
        check(isinstance(toolchain, dict), "build.toolchain must be a mapping")
        if isinstance(toolchain, dict):
            for key in toolchain:
                check(key in ("go", "rust", "msvc"), f"unknown toolchain {key!r}")
            for key, value in toolchain.items():
                if value is not None:
                    check(isinstance(value, str) and bool(value), f"toolchain.{key} must be a version string")
        check(isinstance(build.get("env", {}), dict), "build.env must be a mapping")
        check(isinstance(build.get("overrides", []), list), "build.overrides must be a list")
        epoch = build.get("source_date_epoch")
        check(epoch is None or (isinstance(epoch, int) and epoch > 0),
              "build.source_date_epoch must be a positive integer when set")

    stage = data["stage"]
    check(isinstance(stage, list) and bool(stage), "stage must be a non-empty list")
    if isinstance(stage, list):
        for index, entry in enumerate(stage):
            prefix = f"stage[{index}]"
            if not isinstance(entry, dict):
                problems.append(f"{prefix} must be a mapping")
                continue
            check(bool(entry.get("from")), f"{prefix}.from is required")
            target = entry.get("to")
            check(bool(target), f"{prefix}.to is required")
            if target:
                check(not Path(target).is_absolute() and ".." not in Path(target).parts,
                      f"{prefix}.to must be a relative path inside the archive")

    smoke = data["smoke"]
    check(isinstance(smoke, list), "smoke must be a list")
    if isinstance(smoke, list):
        for index, command in enumerate(smoke):
            check(isinstance(command, list) and bool(command), f"smoke[{index}] must be a non-empty list")

    reproducibility = data["reproducibility"]
    check(isinstance(reproducibility, dict), "reproducibility must be a mapping")
    if isinstance(reproducibility, dict):
        check(reproducibility.get("level") in LEVELS,
              f"reproducibility.level must be one of {', '.join(LEVELS)}")
        check(isinstance(reproducibility.get("ab"), bool), "reproducibility.ab must be a boolean")
        check(isinstance(reproducibility.get("cross_env"), bool), "reproducibility.cross_env must be a boolean")
        check(isinstance(reproducibility.get("verified_on"), list),
              "reproducibility.verified_on must be a list")
        if reproducibility.get("level") in ("L2", "L3"):
            check(bool(reproducibility.get("verified_on")),
                  "reproducibility.verified_on is required for L2/L3")

    check(data["distribution"] in DISTRIBUTIONS,
          f"distribution must be one of {', '.join(DISTRIBUTIONS)}")

    if problems:
        raise Fail(f"{where}: " + "; ".join(problems))
    return data


def load_recipe(name_or_path, root=None):
    root = root or repo_root()
    candidate = Path(name_or_path)
    if candidate.is_dir():
        path = candidate / "package.yml"
    elif candidate.name == "package.yml":
        path = candidate
    else:
        path = root / "packages" / str(name_or_path) / "package.yml"
    if not path.is_file():
        raise Fail(f"no recipe at {path}")
    recipe = Recipe.load(path)
    validate_recipe(recipe)
    return recipe


def all_recipes(root=None):
    root = root or repo_root()
    for path in sorted((root / "packages").glob("*/package.yml")):
        yield Recipe.load(path)


def cmd_plan(args):
    recipe = load_recipe(args.package)
    resolved = recipe.resolved(args.pkgver, args.pkgrel, args.arch)
    build = recipe["build"]
    toolchain = build.get("toolchain", {})
    variables = recipe.variables(resolved["pkgver"], resolved["pkgrel"], resolved["arch"])
    sources = []
    for source in recipe["sources"]:
        entry = {key: source.get(key) for key in ("type", "url", "tag", "commit", "dir", "extract", "sha256")}
        for key in ("url", "tag"):
            if entry.get(key):
                entry[key] = render(entry[key], variables)
        sources.append(entry)
    if args.ids:
        print(json.dumps(["a", "b"] if recipe["reproducibility"]["ab"] else ["a"]))
        return

    plan = {
        "name": resolved["name"],
        "pkgver": resolved["pkgver"],
        "pkgrel": resolved["pkgrel"],
        "arch": resolved["arch"],
        "full": resolved["full"],
        "artifact": resolved["artifact"],
        "runner": build["runner"],
        "shell": build["shell"],
        "toolchain": {key: toolchain.get(key) for key in ("go", "rust", "msvc")},
        "vcvars": toolchain.get("msvc") is not None,
        "publishable": recipe["distribution"] == "allowed",
        "reproducibility": recipe["reproducibility"],
        "sources": sources,
    }
    print(stable_json(plan), end="")


def download(url, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    run(["curl", "--fail", "--silent", "--show-error", "--location", "--retry", "3",
         "--output", str(destination), url])


def verify_tag(source):
    tag = source.get("tag")
    if not tag or source.get("verify_tag", True) is False:
        return
    result = git(["ls-remote", "--tags", source["url"],
                  f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"], capture=True)
    peeled = direct = None
    for line in result.stdout.splitlines():
        sha, _, ref = line.partition("\t")
        if ref.endswith("^{}"):
            peeled = sha
        elif ref == f"refs/tags/{tag}":
            direct = sha
    actual = peeled or direct
    if not actual:
        raise Fail(f"tag {tag} not found in {source['url']}")
    if actual != source["commit"]:
        raise Fail(
            f"tag {tag} now points at {actual}, recipe pins {source['commit']} "
            "— review the change and bump the pin"
        )


def fetch_git(source, destination):
    commit = source["commit"]
    tag = source.get("tag")
    verify_tag(source)
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    git(["init", "--quiet", str(destination)])
    git(["-C", str(destination), "remote", "add", "origin", source["url"]])
    git(["-C", str(destination), "fetch", "--quiet", "--depth", "1", "origin", tag or commit])
    git(["-C", str(destination), "checkout", "--quiet", "--detach", "FETCH_HEAD"])
    head = git(["-C", str(destination), "rev-parse", "HEAD"], capture=True).stdout.strip()
    if head != commit:
        raise Fail(f"{source['url']}: checked out {head}, expected {commit}")
    if source.get("submodules"):
        try:
            git(["-C", str(destination), "submodule", "update", "--init", "--recursive", "--depth", "1"])
        except Fail:
            log("shallow submodules failed, retrying without --depth")
            git(["-C", str(destination), "submodule", "update", "--init", "--recursive"])
    return head


def fetch_url(source, destination, cache):
    url = source["url"]
    expected = source["sha256"]
    cached = cache / expected
    if not cached.is_file() or sha256_file(cached) != expected:
        log(f"downloading {url}")
        download(url, cached)
        actual = sha256_file(cached)
        if actual != expected:
            cached.unlink(missing_ok=True)
            raise Fail(f"sha256 mismatch for {url}: expected {expected}, got {actual}")
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True, exist_ok=True)
    kind = source["extract"]
    if kind == "zip":
        with zipfile.ZipFile(cached) as archive:
            archive.extractall(destination)
    else:
        mode = {"tar.gz": "r:gz", "tar.xz": "r:xz", "tar": "r:"}[kind]
        with tarfile.open(cached, mode) as archive:
            try:
                archive.extractall(destination, filter="data")
            except TypeError:  # Python < 3.12
                archive.extractall(destination)
    return expected


def source_date_epoch(recipe, src_root, variables):
    explicit = recipe["build"].get("source_date_epoch")
    if explicit:
        return int(render(str(explicit), variables))
    for source in recipe["sources"]:
        if source["type"] == "git":
            result = git(["-C", str(src_root / source["dir"]), "log", "-1", "--format=%ct"], capture=True)
            return int(result.stdout.strip())
    return ZIP_EPOCH_MIN


def work_paths(root, build_id, work):
    base = Path(work or root / "work") / build_id
    return {
        "base": base,
        "src": base / "src",
        "out": base / "out",
        "stage": base / "stage",
        "files": base / "files",
    }


def build_env(recipe, resolved, paths, epoch):
    env = dict(os.environ)
    env.update({str(key): str(value) for key, value in (recipe["build"].get("env") or {}).items()})
    env.update(
        {
            "PKG_NAME": resolved["name"],
            "PKG_PKGVER": resolved["pkgver"],
            "PKG_PKGREL": str(resolved["pkgrel"]),
            "PKG_FULL_VERSION": resolved["full"],
            "PKG_ARCH": resolved["arch"],
            "PKG_RECIPE_DIR": str(recipe.dir),
            "PKG_SRC_DIR": str(paths["src"]),
            "PKG_OUT_DIR": str(paths["out"]),
            "PKG_STAGE_DIR": str(paths["stage"]),
            "PKG_FILES_DIR": str(paths["files"]),
            "PKG_WORK_DIR": str(paths["base"]),
            "SOURCE_DATE_EPOCH": str(epoch),
            "PYTHONIOENCODING": "utf-8",
        }
    )
    return env


def cmd_build(args):
    root = repo_root()
    recipe = load_recipe(args.package, root)
    resolved = recipe.resolved(args.pkgver, args.pkgrel, args.arch)
    variables = recipe.variables(resolved["pkgver"], resolved["pkgrel"], resolved["arch"])
    paths = work_paths(root, args.id, args.work)
    paths["src"].mkdir(parents=True, exist_ok=True)
    for key in ("out", "stage", "files"):
        shutil.rmtree(paths[key], ignore_errors=True)
        paths[key].mkdir(parents=True, exist_ok=True)
    if (recipe.dir / "files").is_dir():
        shutil.copytree(recipe.dir / "files", paths["files"], dirs_exist_ok=True)

    for source in recipe["sources"]:
        rendered = {
            **source,
            "url": render(source["url"], variables),
            "tag": render(source["tag"], variables) if source.get("tag") else None,
        }
        destination = paths["src"] / source["dir"]
        if source["type"] == "git":
            fetch_git(rendered, destination)
        else:
            fetch_url(rendered, destination, root / "work" / "cache")

    epoch = source_date_epoch(recipe, paths["src"], variables)
    env = build_env(recipe, resolved, paths, epoch)
    script = (recipe.dir / recipe["build"]["script"]).resolve()
    if recipe["build"]["shell"] == "bash":
        executable = shutil.which("bash")
        if not executable:
            raise Fail("bash is required to run this recipe")
        command = [executable, str(script)]
    else:
        executable = shutil.which("pwsh")
        if not executable:
            raise Fail("pwsh is required to run this recipe")
        command = [executable, "-NoLogo", "-NoProfile", "-File", str(script)]
    run(command, cwd=paths["src"], env=env)

    stage_entries(recipe, resolved, paths, variables)
    log(f"staged into {paths['stage'] / resolved['name']}")


def resolve_stage_source(spec, recipe, paths, variables):
    for prefix, base in (("${out}", paths["out"]), ("${src}", paths["src"]),
                         ("${files}", paths["files"]), ("${recipe}", recipe.dir)):
        if spec == prefix or spec.startswith(prefix + "/"):
            return base / render(spec[len(prefix):].lstrip("/"), variables)
    text = render(spec, variables)
    candidate = Path(text)
    if candidate.is_absolute():
        return candidate
    return paths["src"] / candidate


def stage_entries(recipe, resolved, paths, variables):
    target_root = paths["stage"] / resolved["name"]
    shutil.rmtree(target_root, ignore_errors=True)
    target_root.mkdir(parents=True, exist_ok=True)
    for entry in recipe["stage"]:
        source = resolve_stage_source(entry["from"], recipe, paths, variables)
        target = target_root / render(entry["to"], variables)
        if not source.exists():
            raise Fail(f"{recipe['name']}: staged source {source} does not exist")
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target, dirs_exist_ok=True)
        else:
            shutil.copy2(source, target)


def is_executable(relative_path):
    name = Path(relative_path).name.lower()
    return name.endswith((".exe", ".dll", ".cmd", ".bat", ".ps1")) or name in ("sh", "bash")


def write_deterministic_zip(archive_path, source_root, prefix, epoch):
    stamp = time.gmtime(max(int(epoch), ZIP_EPOCH_MIN))[:6]
    entries = sorted(path for path in source_root.rglob("*") if path.is_file())
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in entries:
            relative = path.relative_to(source_root).as_posix()
            info = zipfile.ZipInfo(f"{prefix}/{relative}", date_time=stamp)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o755 if is_executable(relative) else 0o644) << 16
            archive.writestr(info, path.read_bytes(), compresslevel=9)


def collect_files(target_root):
    files = []
    for path in sorted(target_root.rglob("*")):
        if path.is_file():
            relative = path.relative_to(target_root).as_posix()
            files.append(
                {
                    "path": relative,
                    "size": path.stat().st_size,
                    "sha256": sha256_file(path),
                    "mode": "755" if is_executable(relative) else "644",
                }
            )
    return files


def cmd_package(args):
    root = repo_root()
    recipe = load_recipe(args.package, root)
    resolved = recipe.resolved(args.pkgver, args.pkgrel, args.arch)
    variables = recipe.variables(resolved["pkgver"], resolved["pkgrel"], resolved["arch"])
    paths = work_paths(root, args.id, args.work)
    target_root = paths["stage"] / resolved["name"]
    if not target_root.is_dir():
        raise Fail(f"nothing staged at {target_root}; run build first")

    out_dir = Path(args.out) if args.out else root / "dist"
    out_dir.mkdir(parents=True, exist_ok=True)
    archive_path = out_dir / resolved["artifact"]
    epoch = source_date_epoch(recipe, paths["src"], variables)
    write_deterministic_zip(archive_path, target_root, resolved["name"], epoch)

    manifest = {
        "schema": SCHEMA,
        "name": resolved["name"],
        "summary": recipe["summary"],
        "homepage": recipe["homepage"],
        "license": recipe["license"],
        "distribution": recipe["distribution"],
        "notes": recipe.get("notes"),
        "depends": recipe.get("depends", []),
        "provides": recipe.get("provides", []),
        "conflicts": recipe.get("conflicts", []),
        "version": {"pkgver": resolved["pkgver"], "pkgrel": resolved["pkgrel"], "full": resolved["full"]},
        "arch": resolved["arch"],
        "archive": {
            "file": resolved["artifact"],
            "format": "zip",
            "root": resolved["name"],
            "size": archive_path.stat().st_size,
            "sha256": sha256_file(archive_path),
        },
        "files": collect_files(target_root),
        "sources": [
            {
                "type": source["type"],
                "url": render(source["url"], variables),
                "tag": render(source["tag"], variables) if source.get("tag") else None,
                "commit": source.get("commit"),
                "sha256": source.get("sha256"),
            }
            for source in recipe["sources"]
        ],
        "build": {
            "script": recipe["build"]["script"],
            "shell": recipe["build"]["shell"],
            "runner": recipe["build"]["runner"],
            "recipe_sha256": sha256_file(recipe.path),
            "script_sha256": sha256_file(recipe.dir / recipe["build"]["script"]),
            "env": {str(key): str(value) for key, value in (recipe["build"].get("env") or {}).items()},
            "overrides": recipe["build"].get("overrides", []),
        },
        "toolchain": {
            **{key: recipe["build"].get("toolchain", {}).get(key) for key in ("go", "rust", "msvc")},
            "runner": recipe["build"]["runner"],
            "runner_image": os.environ.get("ImageVersion"),
        },
        "reproducibility": {
            "level": recipe["reproducibility"]["level"],
            "ab": "same-image" if recipe["reproducibility"]["ab"] else "none",
            "ab_verified": False,
            "ab_sha256": [],
            "cross_env": recipe["reproducibility"]["cross_env"],
            "verified_on": recipe["reproducibility"]["verified_on"],
        },
        "source_date_epoch": epoch,
    }
    if args.provenance:
        manifest["provenance"] = json.loads(Path(args.provenance).read_text(encoding="utf-8"))

    write_json(out_dir / manifest_name(resolved), manifest)
    write_sha256sums(out_dir)
    log(f"packaged {archive_path}")
    print(str(archive_path))


def manifest_name(resolved):
    return resolved["artifact"][: -len(".zip")] + ".manifest.json"


def write_sha256sums(out_dir):
    out_dir = Path(out_dir)
    lines = []
    for path in sorted(out_dir.iterdir()):
        if path.is_file() and (path.suffix == ".zip" or path.name.endswith(".manifest.json")):
            lines.append(f"{sha256_file(path)}  {path.name}")
    (out_dir / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def cmd_smoke(args):
    root = repo_root()
    recipe = load_recipe(args.package, root)
    resolved = recipe.resolved(args.pkgver, args.pkgrel, args.arch)
    variables = recipe.variables(resolved["pkgver"], resolved["pkgrel"], resolved["arch"])
    target_root = work_paths(root, args.id, args.work)["stage"] / resolved["name"]
    if not target_root.is_dir():
        raise Fail(f"nothing staged at {target_root}; run build first")
    for command in recipe["smoke"]:
        rendered = [render(str(part), variables) for part in command]
        log(f"smoke: {' '.join(rendered)}")
        result = subprocess.run(rendered, cwd=str(target_root), check=False, text=True,
                                timeout=300, capture_output=True)
        if result.returncode != 0:
            sys.stderr.write(result.stdout or "")
            sys.stderr.write(result.stderr or "")
            raise Fail(f"smoke test failed: {' '.join(rendered)} (exit {result.returncode})")
        for line in (result.stdout or "").strip().splitlines()[:5]:
            print(f"  {line}")


def cmd_assemble(args):
    root = repo_root()
    recipe = load_recipe(args.package, root)
    resolved = recipe.resolved(args.pkgver, args.pkgrel, args.arch)
    out_dir = Path(args.out) if args.out else root / "dist"
    ids = [item.strip() for item in args.ids.split(",") if item.strip()]
    if not ids:
        raise Fail("--ids must name at least one build id")

    digests = []
    manifests = {}
    for build_id in ids:
        manifest_path = out_dir / build_id / manifest_name(resolved)
        if not manifest_path.is_file():
            raise Fail(f"missing manifest {manifest_path} (package with --id {build_id} --out {out_dir / build_id})")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        archive = manifest_path.parent / manifest["archive"]["file"]
        if not archive.is_file():
            raise Fail(f"missing archive {archive}")
        digest = sha256_file(archive)
        if digest != manifest["archive"]["sha256"]:
            raise Fail(f"{archive} does not match its manifest: {digest} != {manifest['archive']['sha256']}")
        digests.append(digest)
        manifests[build_id] = manifest

    if len(set(digests)) > 1:
        differences = sorted(
            build_id for build_id in ids
            if manifests[build_id]["files"] != manifests[ids[0]]["files"]
        )
        raise Fail("archives differ between rebuilds: " + ", ".join(differences))

    chosen = ids[-1]
    manifest = manifests[chosen]
    if len(ids) > 1:
        if len(ids) != 2:
            raise Fail("A/B comparison expects exactly two build ids")
        if not recipe["reproducibility"]["ab"]:
            raise Fail(f"{recipe['name']} does not enable reproducibility.ab")
        manifest["reproducibility"]["ab_verified"] = True
        manifest["reproducibility"]["ab_sha256"] = digests

    for name in (resolved["artifact"], manifest_name(resolved)):
        shutil.copy2(out_dir / chosen / name, out_dir / name)
    write_json(out_dir / manifest_name(resolved), manifest)
    write_sha256sums(out_dir)
    log(f"assembled {resolved['artifact']} (sha256 {digests[0]})")


def cmd_index(args):
    manifests_dir = Path(args.manifests)
    entries = []
    for path in sorted(manifests_dir.glob("*.manifest.json")):
        manifest = json.loads(path.read_text(encoding="utf-8"))
        if manifest.get("distribution") == "private-only" and not args.include_private:
            log(f"skipping private-only package {manifest['name']}")
            continue
        if args.verify:
            archive = manifests_dir / manifest["archive"]["file"]
            if not archive.is_file():
                raise Fail(f"missing archive {archive}")
            if sha256_file(archive) != manifest["archive"]["sha256"]:
                raise Fail(f"archive digest mismatch for {archive}")
        entries.append((path, manifest))

    if not args.repo and not args.base_url:
        raise Fail("index requires --repo or --base-url")

    def location(tag, file_name):
        if args.repo:
            return f"https://github.com/{args.repo}/releases/download/{tag}/{file_name}"
        return f"{args.base_url.rstrip('/')}/{file_name}"

    packages = {}
    for path, manifest in entries:
        name = manifest["name"]
        package = packages.setdefault(
            name,
            {
                "summary": manifest["summary"],
                "homepage": manifest["homepage"],
                "license": manifest["license"],
                "distribution": manifest["distribution"],
                "notes": manifest.get("notes"),
                "depends": manifest.get("depends", []),
                "provides": manifest.get("provides", []),
                "conflicts": manifest.get("conflicts", []),
                "releases": [],
            },
        )
        tag = f"{manifest['name']}/v{manifest['version']['full']}"
        package["releases"].append(
            {
                "pkgver": manifest["version"]["pkgver"],
                "pkgrel": manifest["version"]["pkgrel"],
                "full": manifest["version"]["full"],
                "arch": manifest["arch"],
                "tag": tag,
                "url": location(tag, manifest["archive"]["file"]),
                "size": manifest["archive"]["size"],
                "sha256": manifest["archive"]["sha256"],
                "manifest_url": location(tag, path.name),
                "manifest_sha256": sha256_file(path),
                "source_date_epoch": manifest.get("source_date_epoch"),
                "toolchain": manifest.get("toolchain", {}),
                "reproducibility": manifest.get("reproducibility", {}),
                "provenance": manifest.get("provenance"),
            }
        )

    for package in packages.values():
        package["releases"].sort(
            key=lambda item: (natural_key(item["pkgver"]), item["pkgrel"], item["arch"]), reverse=True
        )
        package["latest"] = package["releases"][0]["full"]

    document = {
        "schema": SCHEMA,
        "repository": {"name": args.name, "repo": args.repo, "base_url": args.base_url},
        "packages": dict(sorted(packages.items())),
    }
    out = Path(args.out)
    write_json(out, document)
    log(f"wrote {out} ({sum(len(p['releases']) for p in packages.values())} releases)")


def cmd_verify(args):
    manifest_path = Path(args.manifest)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    archive = manifest_path.parent / manifest["archive"]["file"]
    if not archive.is_file():
        raise Fail(f"missing archive {archive}")
    actual = sha256_file(archive)
    if actual != manifest["archive"]["sha256"]:
        raise Fail(f"archive digest mismatch: {actual} != {manifest['archive']['sha256']}")
    with zipfile.ZipFile(archive) as package:
        names = sorted(package.namelist())
        expected = sorted(f"{manifest['archive']['root']}/{entry['path']}" for entry in manifest["files"])
        if names != expected:
            raise Fail("archive contents differ from manifest file list")
        for entry in manifest["files"]:
            digest = hashlib.sha256(package.read(f"{manifest['archive']['root']}/{entry['path']}")).hexdigest()
            if digest != entry["sha256"]:
                raise Fail(f"digest mismatch inside archive for {entry['path']}")
    log(f"verified {archive.name}")


def cmd_validate(args):
    root = repo_root()
    problems = []
    recipes = list(all_recipes(root)) if args.all else [load_recipe(args.package, root)]
    names = {}
    for recipe in recipes:
        try:
            validate_recipe(recipe)
        except Fail as error:
            problems.append(str(error))
            continue
        name = recipe["name"]
        if recipe.dir.name != name:
            problems.append(f"{recipe.path}: package name {name!r} must match directory {recipe.dir.name!r}")
        if name in names:
            problems.append(f"{recipe.path}: duplicate package name {name!r}")
        names[name] = recipe.path
        for arch in recipe["arch"]:
            recipe.resolved(arch=arch)
    if problems:
        raise Fail("\n".join(problems))
    print(f"validated {len(recipes)} recipe(s)")


def cmd_lint_workflows(args):
    directory = Path(args.dir)
    paths = sorted(directory.rglob("*.yml"))
    problems = []
    for path in paths:
        text = path.read_text(encoding="utf-8")
        try:
            document = yaml.safe_load(text)
        except yaml.YAMLError as error:
            problems.append(f"{path}: invalid YAML: {error}")
            continue
        if not isinstance(document, dict):
            problems.append(f"{path}: workflow must be a mapping")
            continue
        for job_name, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict) or "uses" in job:
                continue
            if "timeout-minutes" not in job:
                problems.append(f"{path}:{job_name}: timeout-minutes is required")
            runner = job.get("runs-on")
            if isinstance(runner, str) and runner.endswith("-latest"):
                problems.append(f"{path}:{job_name}: runs-on {runner} must be pinned to an explicit image")
        if document.get("permissions") == "write-all":
            problems.append(f"{path}: permissions: write-all is forbidden")
        for match in re.finditer(r"^\s*(?:-\s*)?uses:\s*(\S+)\s*$", text, re.MULTILINE):
            target = match.group(1)
            if not target.startswith("./") and not USES_RE.match(target):
                problems.append(f"{path}: action {target} is not pinned to a full commit SHA")
    if problems:
        raise Fail("\n".join(problems))
    print(f"linted {len(paths)} workflow file(s)")


def env_pkgrel():
    # The dispatch input is a string so it can be forwarded through a reusable
    # workflow; empty means "keep the recipe value".
    raw = (os.environ.get("PKGREL") or "").strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        raise SystemExit(f"PKGREL must be an integer, got {raw!r}")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="pkgctl")
    sub = parser.add_subparsers(dest="command", required=True)

    def common(target):
        # The workflows export PACKAGE/PKGVER/PKGREL/ARCH/WORK, so they can call
        # pkgctl without a shell wrapper; explicit flags still win.
        package = os.environ.get("PACKAGE") or None
        target.add_argument("--package", default=package, required=package is None)
        target.add_argument("--pkgver", default=os.environ.get("PKGVER") or None)
        target.add_argument("--pkgrel", type=int, default=env_pkgrel())
        target.add_argument("--arch", default=os.environ.get("ARCH") or None)
        target.add_argument("--work", default=os.environ.get("WORK") or None)

    plan = sub.add_parser("plan")
    common(plan)
    plan.add_argument("--ids", action="store_true")
    plan.set_defaults(func=cmd_plan)

    build = sub.add_parser("build")
    common(build)
    build.add_argument("--id", default="a")
    build.set_defaults(func=cmd_build)

    package = sub.add_parser("package")
    common(package)
    package.add_argument("--id", default="a")
    package.add_argument("--out")
    package.add_argument("--provenance")
    package.set_defaults(func=cmd_package)

    smoke = sub.add_parser("smoke")
    common(smoke)
    smoke.add_argument("--id", default="a")
    smoke.set_defaults(func=cmd_smoke)

    for name, default_ids in (("assemble", "a"), ("ab", "a,b")):
        target = sub.add_parser(name)
        common(target)
        target.add_argument("--ids", default=default_ids)
        target.add_argument("--out")
        target.set_defaults(func=cmd_assemble)

    index = sub.add_parser("index")
    index.add_argument("--manifests", required=True)
    index.add_argument("--out", required=True)
    index.add_argument("--repo", help="owner/name used to build GitHub release URLs")
    index.add_argument("--base-url", help="flat download base used when --repo is absent")
    index.add_argument("--name", default="buildsmith")
    index.add_argument("--include-private", action="store_true")
    index.add_argument("--verify", action="store_true")
    index.set_defaults(func=cmd_index)

    verify = sub.add_parser("verify")
    verify.add_argument("--manifest", required=True)
    verify.set_defaults(func=cmd_verify)

    validate = sub.add_parser("validate")
    validate.add_argument("--package")
    validate.add_argument("--all", action="store_true")
    validate.set_defaults(func=cmd_validate)

    lint = sub.add_parser("lint-workflows")
    lint.add_argument("--dir", default=str(repo_root() / ".github" / "workflows"))
    lint.set_defaults(func=cmd_lint_workflows)

    args = parser.parse_args(argv)
    if args.command == "validate" and not args.all and not args.package:
        parser.error("validate requires --package or --all")
    try:
        args.func(args)
    except Fail as error:
        sys.stderr.write(f"pkgctl: error: {error}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())