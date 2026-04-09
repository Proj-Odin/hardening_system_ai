#!/usr/bin/env python3
"""Check that Alpine hardening stays aligned with the shared Debian flow."""

from __future__ import annotations

from pathlib import Path
import difflib
import re
import sys


ROOT = Path(__file__).resolve().parent
DEBIAN_SCRIPT = ROOT / "system_hardening.sh"
ALPINE_SCRIPT = ROOT / "system_hardening_alpine.sh"
FUNCTION_RE = re.compile(r"^([A-Za-z0-9_]+)\(\) \{$")

ALPINE_ONLY_FUNCTIONS = {
    "choose_deployment_target",
    "enable_service_now",
    "ensure_sshd_include_dropin",
    "post_apply_services_hint",
    "reload_or_restart_service",
    "service_exists",
}

ALLOWED_SHARED_DIFFS = {
    "apply_all_changes",
    "apply_apparmor",
    "apply_checkmk",
    "apply_fail2ban",
    "apply_profile_specific",
    "apply_ssh_hardening",
    "apply_tailscale_gateway_profile",
    "apply_tailscale_strong_admin_controls",
    "apply_ufw",
    "apply_update_mode",
    "build_change_plan_preview",
    "configure_apparmor",
    "configure_checkmk_prompt",
    "configure_fail2ban",
    "configure_firewall_prompt",
    "configure_profile_prompt",
    "configure_tailscale_gateway_prompt",
    "configure_unattended_upgrades",
    "detect_environment",
    "install_queued_packages",
    "install_tailscale_package",
    "main",
    "prepare_package_queue",
    "print_post_apply",
    "run_interactive_wizard",
    "show_summary",
}


def parse_functions(path: Path) -> tuple[dict[str, list[str]], list[str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    headers: list[tuple[int, str]] = []
    for idx, line in enumerate(lines):
        match = FUNCTION_RE.match(line)
        if match:
            headers.append((idx, match.group(1)))

    functions: dict[str, list[str]] = {}
    order: list[str] = []
    for index, (start, name) in enumerate(headers):
        end = headers[index + 1][0] if index + 1 < len(headers) else len(lines)
        functions[name] = lines[start:end]
        order.append(name)
    return functions, order


def diff_preview(left: list[str], right: list[str], name: str) -> str:
    preview = difflib.unified_diff(
        left,
        right,
        fromfile=f"system_hardening.sh:{name}",
        tofile=f"system_hardening_alpine.sh:{name}",
        lineterm="",
    )
    return "\n".join(list(preview)[:40])


def main() -> int:
    debian_funcs, debian_order = parse_functions(DEBIAN_SCRIPT)
    alpine_funcs, alpine_order = parse_functions(ALPINE_SCRIPT)

    errors: list[str] = []

    debian_only = sorted(set(debian_funcs) - set(alpine_funcs))
    if debian_only:
        errors.append(
            "Alpine is missing shared functions from system_hardening.sh: "
            + ", ".join(debian_only)
        )

    alpine_only = set(alpine_funcs) - set(debian_funcs)
    unexpected_alpine_only = sorted(alpine_only - ALPINE_ONLY_FUNCTIONS)
    if unexpected_alpine_only:
        errors.append(
            "Unexpected Alpine-only helper functions found: "
            + ", ".join(unexpected_alpine_only)
        )

    missing_expected_helpers = sorted(ALPINE_ONLY_FUNCTIONS - alpine_only)
    if missing_expected_helpers:
        errors.append(
            "Expected Alpine-only helper functions are missing: "
            + ", ".join(missing_expected_helpers)
        )

    shared_debian_order = [name for name in debian_order if name in alpine_funcs]
    shared_alpine_order = [name for name in alpine_order if name in debian_funcs]
    if shared_debian_order != shared_alpine_order:
        errors.append(
            "Shared function order drifted between the Debian and Alpine scripts."
        )

    unexpected_diff_names: list[str] = []
    diff_previews: list[str] = []
    exact_match_count = 0

    for name in shared_debian_order:
        if debian_funcs[name] == alpine_funcs[name]:
            exact_match_count += 1
            continue
        if name not in ALLOWED_SHARED_DIFFS:
            unexpected_diff_names.append(name)
            diff_previews.append(diff_preview(debian_funcs[name], alpine_funcs[name], name))

    if unexpected_diff_names:
        errors.append(
            "Unexpected shared-function drift detected: "
            + ", ".join(unexpected_diff_names)
        )

    if errors:
        print("Hardening mirror check failed.", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        for preview in diff_previews:
            if preview:
                print("\n" + preview, file=sys.stderr)
        return 1

    approved_diff_count = len(ALLOWED_SHARED_DIFFS)
    alpine_helper_count = len(alpine_only)
    print("Hardening mirror check passed.")
    print(f"- Exact shared function matches: {exact_match_count}")
    print(f"- Approved Alpine-specific shared overrides: {approved_diff_count}")
    print(f"- Alpine-only helper functions: {alpine_helper_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
