"""Build the all-in-one TPTS release ZIP (Windows, Linux, and Android local mode).

Usage: python tools/build_release.py v1.0.1 [--skip-build]
Output: dist/TPTS-<version>-full.zip with a single top-level TPTS/ folder.
"""
import argparse
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
CACHE = DIST / "cache"

GEEKBENCH_DIR = "Geekbench-7.0.0-Android-Corporate"
GEEKBENCH_URL = "https://github.com/gracekao/TPTS/releases/download/geekbench-7.0.0/Geekbench-7.0.0-Android-Corporate.zip"
GEEKBENCH_REQUIRED = ["geekbench_avx2", "geekbench_aarch64", "geekbench.plxr", "geekbench-workload.plxr"]
LINUX_ADB_URL = "https://dl.google.com/android/repository/platform-tools-latest-linux.zip"

INCLUDE = [
    "README.md", "TPTS.md", "start.bat", "start.sh", "start_android.sh", "download_geekbench.bat",
    "app", "device_tools", "docs",
    "proxy/adb.exe", "proxy/AdbWinApi.dll", "proxy/AdbWinUsbApi.dll",
    "proxy/tpts_backend.exe", "proxy/tpts_backend_linux_amd64", "proxy/tpts_backend_android_arm64",
]
LF_ONLY = {"start.sh", "start_android.sh", "device_tools/run_stressapp.sh"}
EXECUTABLE = {
    "start.sh", "start_android.sh", "device_tools/run_stressapp.sh", "device_tools/iotools",
    "proxy/adb", "proxy/tpts_backend_linux_amd64", "proxy/tpts_backend_android_arm64",
    f"stress_apk/{GEEKBENCH_DIR}/geekbench_avx2", f"stress_apk/{GEEKBENCH_DIR}/geekbench_aarch64",
}
BACKENDS = [
    ("windows", "amd64", "tpts_backend.exe"),
    ("linux", "amd64", "tpts_backend_linux_amd64"),
    ("android", "arm64", "tpts_backend_android_arm64"),
]


def log(message):
    print(f"[release] {message}", flush=True)


def download(url, dest):
    if dest.exists():
        return dest
    log(f"Downloading {url}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url) as response, open(tmp, "wb") as out:
        shutil.copyfileobj(response, out)
    tmp.replace(dest)
    return dest


def build_backends():
    for goos, goarch, name in BACKENDS:
        log(f"go build {goos}/{goarch} -> proxy/{name}")
        env = dict(os.environ, GOOS=goos, GOARCH=goarch, CGO_ENABLED="0")
        subprocess.run(["go", "build", "-trimpath", "-o", name, "."], cwd=ROOT / "proxy", env=env, check=True)


def geekbench_source():
    local = ROOT / "stress_apk" / GEEKBENCH_DIR
    if all((local / name).is_file() for name in GEEKBENCH_REQUIRED):
        return local
    extracted = CACHE / "geekbench"
    if not all((extracted / GEEKBENCH_DIR / name).is_file() for name in GEEKBENCH_REQUIRED):
        with zipfile.ZipFile(download(GEEKBENCH_URL, CACHE / "geekbench.zip")) as archive:
            archive.extractall(extracted)
    result = extracted / GEEKBENCH_DIR
    missing = [name for name in GEEKBENCH_REQUIRED if not (result / name).is_file()]
    if missing:
        sys.exit(f"Geekbench package is incomplete, missing: {missing}")
    return result


def linux_adb():
    target = CACHE / "adb-linux"
    if not target.exists():
        with zipfile.ZipFile(download(LINUX_ADB_URL, CACHE / "platform-tools-linux.zip")) as archive:
            target.write_bytes(archive.read("platform-tools/adb"))
    return target


def collect_files():
    files = {}
    for entry in INCLUDE:
        path = ROOT / entry
        if path.is_dir():
            for child in sorted(path.rglob("*")):
                if child.is_file():
                    files[child.relative_to(ROOT).as_posix()] = child
        elif path.is_file():
            files[entry] = path
        else:
            sys.exit(f"Missing release file: {entry}")
    gb = geekbench_source()
    for child in sorted(gb.rglob("*")):
        if child.is_file():
            files[f"stress_apk/{GEEKBENCH_DIR}/{child.relative_to(gb).as_posix()}"] = child
    files["proxy/adb"] = linux_adb()
    return files


def check_line_endings(files):
    for rel in LF_ONLY:
        if b"\r\n" in files[rel].read_bytes():
            sys.exit(f"{rel} has CRLF line endings; it must use LF to run on Linux/Android.")


def write_zip(files, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    dirs = {"TPTS/", "TPTS/logs/"}
    for rel in files:
        parts = rel.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("TPTS/" + "/".join(parts[:i]) + "/")
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name in sorted(dirs):
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = (0o40755 << 16) | 0x10
            archive.writestr(info, b"")
        for rel, src in sorted(files.items()):
            info = zipfile.ZipInfo.from_file(src, "TPTS/" + rel)
            info.create_system = 3
            info.external_attr = (0o100755 if rel in EXECUTABLE else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(src, "rb") as data, archive.open(info, "w") as out:
                shutil.copyfileobj(data, out, 1024 * 1024)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version", help="release version, for example v1.0.1")
    parser.add_argument("--skip-build", action="store_true", help="package existing proxy binaries without rebuilding")
    args = parser.parse_args()

    if not args.skip_build:
        build_backends()
    files = collect_files()
    check_line_endings(files)
    output = DIST / f"TPTS-{args.version}-full.zip"
    log(f"Writing {output.relative_to(ROOT)} ({len(files)} files)")
    write_zip(files, output)
    log(f"Done: {output} ({output.stat().st_size / 1024 / 1024:.1f} MB)")


if __name__ == "__main__":
    main()
