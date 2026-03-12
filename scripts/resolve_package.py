#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import re
import shlex
import tomllib


ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGES_DIR = ROOT / "packages"
BUILD_DIR = ROOT / "build"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", required=True)
    parser.add_argument("--target-os", required=True)
    parser.add_argument("--target-arch", required=True)
    parser.add_argument("--upstream-ref", default="")
    parser.add_argument("--release-version", default="")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--archive-format", default="")
    parser.add_argument("--github-output", default="")
    parser.add_argument("--github-env", default="")
    return parser.parse_args()


def load_manifest(package_id: str) -> tuple[pathlib.Path, dict]:
    manifest_path = PACKAGES_DIR / f"{package_id}.toml"
    if not manifest_path.exists():
        raise SystemExit(
            f"Unknown package '{package_id}'. Expected manifest at {manifest_path}."
        )
    return manifest_path, tomllib.loads(manifest_path.read_text())


def normalize_revision(raw: str) -> str:
    value = raw.strip()
    match = re.fullmatch(r"(?:-?r|\.?)?(\d+)", value)
    if not match:
        raise SystemExit(
            "Revision must look like 1, r1, -r1 or .1."
        )
    return f"r{match.group(1)}"


def pick_target(data: dict, target_os: str, target_arch: str) -> dict:
    for target in data.get("targets", []):
        if target.get("os") == target_os and target.get("arch") == target_arch:
            return target
    raise SystemExit(
        f"No target matched os={target_os!r} arch={target_arch!r} for package {data['id']}."
    )


def resolve_version(manifest: dict, upstream_ref_override: str, version_override: str) -> tuple[str, str]:
    upstream = manifest["upstream"]
    upstream_ref = upstream_ref_override.strip() or upstream["ref"]
    release_version = version_override.strip() or upstream.get("version") or upstream_ref
    return upstream_ref, release_version


def default_commands(system: str) -> list[str]:
    defaults = {
        "cmake": [
            "cmake -S . -B build -DCMAKE_BUILD_TYPE=Release",
            "cmake --build build --parallel \"${BUILD_JOBS}\"",
        ],
        "cargo": [
            "CARGO_BUILD_JOBS=\"${BUILD_JOBS}\" cargo build --release --locked",
        ],
        "make": [
            "make -j\"${BUILD_JOBS}\"",
        ],
    }
    if system == "custom":
        raise SystemExit("Custom build systems require explicit build.commands.")
    try:
        return defaults[system]
    except KeyError as exc:
        raise SystemExit(f"Unsupported build system: {system!r}.") from exc


def format_template(template: str, values: dict[str, str]) -> str:
    return template.format(**values)


def write_lines(path: pathlib.Path, items: list[str]) -> None:
    path.write_text("".join(f"{item}\n" for item in items))


def shell_quote(value: str) -> str:
    return shlex.quote(value)


def main() -> int:
    args = parse_args()
    BUILD_DIR.mkdir(exist_ok=True)
    manifest_path, manifest = load_manifest(args.package)

    if manifest.get("schema_version") != 1:
        raise SystemExit("Only schema_version = 1 is supported.")

    target = pick_target(manifest, args.target_os, args.target_arch)
    upstream_ref, release_version = resolve_version(
        manifest, args.upstream_ref, args.release_version
    )
    revision = normalize_revision(args.revision)

    build = manifest["build"]
    release = manifest.get("release", {})
    archive_format = args.archive_format.strip() or target.get("archive", "tar.gz")
    if archive_format not in {"tar.gz", "tar.zst"}:
        raise SystemExit(f"Unsupported archive format: {archive_format}")

    values = {
        "package": manifest["id"],
        "name": manifest["name"],
        "version": release_version,
        "revision": revision,
        "os": args.target_os,
        "arch": args.target_arch,
    }
    archive_basename = format_template(
        release.get("archive_template", "{package}-{version}-{revision}-{os}-{arch}"),
        values,
    )
    archive_extension = ".tar.gz" if archive_format == "tar.gz" else ".tar.zst"
    archive_filename = f"{archive_basename}{archive_extension}"
    release_tag = format_template(
        release.get("tag_template", "{package}/{version}-{revision}"),
        values,
    )
    release_name = format_template(
        release.get("name_template", "{name} {version} ({revision})"),
        values,
    )

    commands = build.get("commands") or default_commands(build["system"])
    build_env = build.get("env", {})
    dependencies = build.get("dependencies", [])
    dependency_setup_commands = build.get("dependency_setup_commands", [])
    output_files = target.get("output_files", [])
    if not output_files:
        raise SystemExit("Target definition must include at least one output file.")

    release_notes = "\n".join(
        part
        for part in [
            release.get("notes", "").strip(),
            "## Build metadata",
            f"- Package: `{manifest['id']}`",
            f"- Upstream repo: `{manifest['upstream']['repo']}`",
            f"- Upstream ref: `{upstream_ref}`",
            f"- Upstream version: `{release_version}`",
            f"- Internal revision: `{revision}`",
            f"- Target: `{args.target_os}/{args.target_arch}`",
            f"- Build system: `{build['system']}`",
            f"- Manifest: `{manifest_path.relative_to(ROOT)}`",
        ]
        if part
    )

    write_lines(BUILD_DIR / "build-commands.txt", commands)
    write_lines(BUILD_DIR / "build-dependencies.txt", dependencies)
    write_lines(BUILD_DIR / "dependency-setup-commands.txt", dependency_setup_commands)
    write_lines(BUILD_DIR / "output-files.txt", output_files)
    (BUILD_DIR / "build-env.json").write_text(json.dumps(build_env, indent=2, sort_keys=True))
    (BUILD_DIR / "release-notes.md").write_text(f"{release_notes}\n")

    resolved_env = {
        "PACKAGE_ID": manifest["id"],
        "PACKAGE_NAME": manifest["name"],
        "PACKAGE_DESCRIPTION": manifest.get("description", ""),
        "MANIFEST_PATH": str(manifest_path),
        "UPSTREAM_REPO": manifest["upstream"]["repo"],
        "UPSTREAM_REF": upstream_ref,
        "UPSTREAM_VERSION": release_version,
        "RELEASE_REVISION": revision,
        "RELEASE_TAG": release_tag,
        "RELEASE_NAME": release_name,
        "BUILD_SYSTEM": build["system"],
        "BUILD_SUBDIR": build.get("subdir", "."),
        "TARGET_OS": args.target_os,
        "TARGET_ARCH": args.target_arch,
        "ARCHIVE_FORMAT": archive_format,
        "ARCHIVE_BASENAME": archive_basename,
        "ARCHIVE_FILENAME": archive_filename,
        "CHECKSUM_FILENAME": f"{archive_basename}.sha256",
        "RELEASE_NOTES_FILE": str(BUILD_DIR / "release-notes.md"),
        "BUILD_COMMANDS_FILE": str(BUILD_DIR / "build-commands.txt"),
        "BUILD_DEPENDENCIES_FILE": str(BUILD_DIR / "build-dependencies.txt"),
        "DEPENDENCY_SETUP_COMMANDS_FILE": str(BUILD_DIR / "dependency-setup-commands.txt"),
        "BUILD_ENV_FILE": str(BUILD_DIR / "build-env.json"),
        "OUTPUT_FILES_FILE": str(BUILD_DIR / "output-files.txt"),
        "SOURCE_DIR": str(BUILD_DIR / "source"),
        "PACKAGE_STAGE_DIR": str(BUILD_DIR / "stage"),
        "DIST_DIR": str(ROOT / "dist"),
    }

    (BUILD_DIR / "resolved.env").write_text(
        "".join(f"{key}={shell_quote(value)}\n" for key, value in resolved_env.items())
    )
    (BUILD_DIR / "resolved.json").write_text(json.dumps(resolved_env, indent=2))

    outputs = {
        "package_id": manifest["id"],
        "release_tag": release_tag,
        "release_name": release_name,
        "archive_filename": archive_filename,
        "archive_basename": archive_basename,
        "checksum_filename": f"{archive_basename}.sha256",
        "release_notes_file": str(BUILD_DIR / "release-notes.md"),
        "manifest_path": str(manifest_path.relative_to(ROOT)),
        "target": f"{args.target_os}/{args.target_arch}",
        "build_system": build["system"],
        "publish_summary": base64.b64encode(release_notes.encode()).decode(),
    }

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            for key, value in outputs.items():
                handle.write(f"{key}={value}\n")

    if args.github_env:
        with open(args.github_env, "a", encoding="utf-8") as handle:
            for key, value in resolved_env.items():
                handle.write(f"{key}={value}\n")

    print(json.dumps(outputs, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
