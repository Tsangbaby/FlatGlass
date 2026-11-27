"""Stage the launchd job and resolve the package icon's absolute path."""

from argparse import ArgumentParser
from pathlib import Path
import plistlib
import re


JOB_PATH = Path("Library/LaunchDaemons/local.lumid.flatglass.plist")
TOKEN = "@THEOS_PACKAGE_INSTALL_PREFIX@"
ICON_PATH = "/Library/PreferenceBundles/FlatGlassPrefs.bundle/icon@3x.png"
# Archive prefix and control architecture, not the runtime jailbreak root.
PACKAGE_LAYOUTS = {
    "": ("", "iphoneos-arm"),
    "rootless": ("/var/jb", "iphoneos-arm64"),
    "roothide": ("", "iphoneos-arm64e"),
}


def stage_job(stage: Path, prefix: str) -> None:
    template = Path(__file__).resolve().parents[1] / "templates" / (JOB_PATH.name + ".in")
    text = template.read_text(encoding="utf-8")
    if text.count(TOKEN) != 1:
        raise SystemExit("FlatGlass: launchd template must contain one prefix placeholder")
    payload = text.replace(TOKEN, prefix).encode("utf-8")
    job = plistlib.loads(payload)
    if job.get("ProgramArguments") != [prefix + "/usr/libexec/flatglass", "--watch"]:
        raise SystemExit("FlatGlass: invalid launchd program path")
    output = stage / JOB_PATH
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(payload)
    output.chmod(0o644)


def resolve_control(stage: Path, scheme: str, prefix: str) -> None:
    path = stage / "DEBIAN/control"
    text = path.read_text(encoding="utf-8")
    architectures = re.findall(r"^Architecture: (.+)$", text, flags=re.MULTILINE)
    expected = PACKAGE_LAYOUTS[scheme][1]
    if architectures != [expected]:
        raise SystemExit(f"FlatGlass: expected package architecture {expected} for prefix {prefix!r}")
    if scheme == "roothide":
        # The installed path changes with jbroot; do not publish a fixed file URL.
        text, replaced = re.subn(r"^Icon: [^\n]*\n", "", text, flags=re.MULTILINE)
    else:
        text, replaced = re.subn(r"^Icon: .*?$", "Icon: file://" + prefix + ICON_PATH,
                                 text, flags=re.MULTILINE)
    if replaced != 1:
        raise SystemExit("FlatGlass: expected one Icon field in staged Debian control")
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", choices=("", "/var/jb"), required=True)
    parser.add_argument("--scheme", choices=PACKAGE_LAYOUTS)
    parser.add_argument("--control", action="store_true", help="resolve the staged Debian control instead")
    parser.add_argument("stage", type=Path)
    args = parser.parse_args()
    scheme = args.scheme if args.scheme is not None else ("rootless" if args.prefix else "")
    if args.prefix != PACKAGE_LAYOUTS[scheme][0]:
        parser.error(f"invalid archive prefix {args.prefix!r} for {scheme or 'rootful'}")
    if args.control:
        resolve_control(args.stage, scheme, args.prefix)
    else:
        # RootHide launchctl translates the jbroot-relative program at load.
        stage_job(args.stage, args.prefix)


if __name__ == "__main__":
    main()
