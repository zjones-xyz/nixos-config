#!/usr/bin/env python3
"""Validate galactica's Homepage dashboard configs (hosts/galactica/homepage).

yamllint already covers syntax, indentation and duplicate mapping keys. This
covers the things that parse fine and still produce a broken dashboard — the
mistakes a routine "add the service that just migrated off Tower" edit makes:

  * a service entry with `href` but no `siteMonitor`, so it silently loses its
    up/down dot while every neighbour has one
  * a `layout:` group in settings.yaml that no longer matches any group in
    services.yaml (Homepage renders the group unstyled, at the bottom)
  * a calendar integration pointing at a service_group/service_name that was
    renamed or removed
  * a widget referencing a {{HOMEPAGE_VAR_*}} the instance's sops env template
    does not define — which on the guest instance is a security boundary, not
    a typo: it is publicly reachable through Pangolin and deliberately carries
    only the three keys its calendar needs
  * a guest link pointing at an internal-only name, which resolves for nobody
    off-network

Instance metadata (env vars, public-facing flag) is passed in as JSON by
flake.nix, read back out of the evaluated sops templates so this can never
drift from what the containers actually receive.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

VAR_RE = re.compile(r"\{\{(HOMEPAGE_VAR_[A-Z0-9_]+)\}\}")

# Names reachable only from the LAN/tailnet. A guest-facing link to one of
# these is a dead link for the audience that dashboard exists for.
INTERNAL_SUFFIXES = (".internal", ".arr.zjones.dev", ".monitor.zjones.dev")

CONFIG_FILES = ("settings.yaml", "services.yaml", "bookmarks.yaml", "widgets.yaml")


class Findings:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def add(self, where: str, message: str) -> None:
        self.errors.append(f"{where}: {message}")

    def __bool__(self) -> bool:
        return bool(self.errors)


def load_yaml(path: Path, findings: Findings):
    try:
        return yaml.safe_load(path.read_text()) or []
    except yaml.YAMLError as exc:
        findings.add(str(path), f"not valid YAML: {exc}")
        return None


def parse_single_key(entry, where: str, findings: Findings, kind: str):
    """Homepage nests everything as a list of one-key mappings."""
    if not isinstance(entry, dict):
        findings.add(where, f"expected a {kind} mapping, got {type(entry).__name__}")
        return None, None
    if len(entry) != 1:
        findings.add(
            where,
            f"expected exactly one {kind} per list entry, got {len(entry)}: "
            f"{sorted(entry)} — check the indentation of the '- ' bullets",
        )
        return None, None
    return next(iter(entry.items()))


def parse_services(doc, where: str, findings: Findings) -> dict[str, dict]:
    """-> {group name: {service name: fields}}"""
    groups: dict[str, dict] = {}
    if doc in (None, []):
        return groups
    if not isinstance(doc, list):
        findings.add(where, "top level must be a list of groups")
        return groups

    for raw_group in doc:
        group_name, members = parse_single_key(raw_group, where, findings, "group")
        if group_name is None:
            continue
        if group_name in groups:
            findings.add(where, f"group {group_name!r} is declared twice")
            continue
        if not isinstance(members, list):
            findings.add(where, f"group {group_name!r} must contain a list of services")
            continue

        services: dict[str, dict] = {}
        for raw_service in members:
            svc_name, fields = parse_single_key(
                raw_service, f"{where} [{group_name}]", findings, "service"
            )
            if svc_name is None:
                continue
            if svc_name in services:
                findings.add(
                    where, f"service {svc_name!r} is declared twice in group {group_name!r}"
                )
                continue
            services[svc_name] = fields if isinstance(fields, dict) else {}
        groups[group_name] = services

    return groups


def check_services(groups, where, public_facing, findings) -> None:
    for group_name, services in groups.items():
        for svc_name, fields in services.items():
            label = f"{where} [{group_name} / {svc_name}]"
            href = fields.get("href")

            if href is None:
                # A widget-only tile with no link is legitimate; nothing to check.
                continue
            if not isinstance(href, str) or not href.startswith(("http://", "https://")):
                findings.add(label, f"href is not an http(s) URL: {href!r}")
                continue

            monitor = fields.get("siteMonitor")
            if monitor is None:
                findings.add(
                    label,
                    "has href but no siteMonitor — every entry gets a live up/down "
                    f"dot, so add `siteMonitor: {href}`",
                )
            elif monitor != href:
                findings.add(
                    label,
                    f"siteMonitor ({monitor!r}) does not match href ({href!r}); "
                    "they are kept identical so the dot reflects the link",
                )

            if public_facing and href.endswith(INTERNAL_SUFFIXES):
                findings.add(
                    label,
                    f"href {href!r} is an internal-only name, but this dashboard is "
                    "reachable from the public internet — guests cannot resolve it",
                )


def check_layout(settings, groups, where, findings) -> None:
    if not isinstance(settings, dict):
        return
    layout = settings.get("layout")
    if layout is None:
        return
    if not isinstance(layout, dict):
        findings.add(where, "layout must be a mapping of group name -> options")
        return

    for group_name in layout:
        if group_name not in groups:
            findings.add(
                where,
                f"layout styles group {group_name!r}, which no longer exists in "
                f"services.yaml (has: {sorted(groups) or 'none'})",
            )
    for group_name in groups:
        if group_name not in layout:
            findings.add(
                where,
                f"services.yaml defines group {group_name!r} with no layout entry — "
                "it will render unstyled below the styled groups",
            )


def check_widget_service_refs(widgets, groups, where, findings) -> None:
    if not isinstance(widgets, list):
        return
    for raw_widget in widgets:
        if not isinstance(raw_widget, dict):
            continue
        for widget_name, body in raw_widget.items():
            if not isinstance(body, dict):
                continue
            for integration in body.get("integrations") or []:
                if not isinstance(integration, dict):
                    continue
                group_name = integration.get("service_group")
                svc_name = integration.get("service_name")
                if group_name is None and svc_name is None:
                    # A self-contained integration (its own url/key) — fine.
                    continue
                label = f"{where} [{widget_name}]"
                if group_name is None or svc_name is None:
                    findings.add(
                        label,
                        "integration sets only one of service_group/service_name; "
                        "it needs both to resolve a service",
                    )
                    continue
                if group_name not in groups:
                    findings.add(
                        label,
                        f"integration references group {group_name!r}, absent from "
                        f"services.yaml (has: {sorted(groups) or 'none'})",
                    )
                elif svc_name not in groups[group_name]:
                    findings.add(
                        label,
                        f"integration references service {svc_name!r} in group "
                        f"{group_name!r}, which has: "
                        f"{sorted(groups[group_name]) or 'no services'}",
                    )


def check_env_vars(instance_dir, instance, declared, findings) -> None:
    used: dict[str, str] = {}
    for name in CONFIG_FILES:
        path = instance_dir / name
        if not path.exists():
            continue
        for var in VAR_RE.findall(path.read_text()):
            used.setdefault(var, f"{instance}/{name}")

    for var, where in sorted(used.items()):
        if var not in declared:
            findings.add(
                where,
                f"uses {{{{{var}}}}}, which the {instance} sops env template does "
                f"not define (it defines: {', '.join(sorted(declared)) or 'nothing'}). "
                "Add it in homepages.nix, or point the widget at a service whose key "
                "this instance already carries.",
            )

    for var in sorted(set(declared) - set(used)):
        findings.add(
            f"homepages.nix [{instance}]",
            f"declares {var} but no config file uses it — drop it rather than "
            "handing the container a credential it has no use for",
        )


def validate_instance(config_dir: Path, instance: str, meta: dict, findings: Findings) -> None:
    instance_dir = config_dir / instance
    if not instance_dir.is_dir():
        findings.add(str(instance_dir), "instance directory is missing")
        return

    missing = [name for name in CONFIG_FILES if not (instance_dir / name).exists()]
    if missing:
        findings.add(f"{instance}/", f"missing config file(s): {', '.join(missing)}")

    services_doc = load_yaml(instance_dir / "services.yaml", findings)
    groups = parse_services(services_doc, f"{instance}/services.yaml", findings)

    check_services(
        groups, f"{instance}/services.yaml", meta.get("publicFacing", False), findings
    )
    check_layout(
        load_yaml(instance_dir / "settings.yaml", findings),
        groups,
        f"{instance}/settings.yaml",
        findings,
    )
    check_widget_service_refs(
        load_yaml(instance_dir / "widgets.yaml", findings),
        groups,
        f"{instance}/widgets.yaml",
        findings,
    )
    check_env_vars(instance_dir, instance, meta.get("env", []), findings)

    # bookmarks.yaml has no cross-file relationships; parsing it is the check.
    load_yaml(instance_dir / "bookmarks.yaml", findings)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-dir", required=True, type=Path)
    parser.add_argument(
        "--instances",
        required=True,
        help='JSON: {"admin": {"env": [...], "publicFacing": false}, ...}',
    )
    args = parser.parse_args()

    instances = json.loads(args.instances)
    findings = Findings()

    for instance in sorted(instances):
        validate_instance(args.config_dir, instance, instances[instance], findings)

    if findings:
        print("Homepage config validation failed:\n", file=sys.stderr)
        for error in findings.errors:
            print(f"  ✗ {error}", file=sys.stderr)
        print(
            f"\n{len(findings.errors)} problem(s) found in {args.config_dir}.",
            file=sys.stderr,
        )
        return 1

    print(f"Homepage config OK ({', '.join(sorted(instances))}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
