#!/bin/bash
# ===========================================================================
# Build the Nginx-for-TOS Docker application package (<appid>.tar.gz + .sha256)
#
# Usage: scripts/build.sh [version] [platform]
#   version  default: 1.29.8-1   (format: <upstream>-<packaging iteration>)
#   platform default: x86_64     (TOS asset naming has no platform suffix for
#                                 Docker apps, but config.ini.platform must
#                                 match the architecture being submitted)
#
# The whole build is pure Python + tar/gzip: no dpkg, no docker, no network.
# ===========================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
SRC="$ROOT/src"
STAGE="$ROOT/build/stage"
OUT="$ROOT/out"
APPID="nginxdocker"

# --- upstream image pin -----------------------------------------------------
# The compose file is the single source of truth for the image reference; the
# numeric part of the tag is the upstream version the package version is built
# from, so the two can never drift apart unnoticed.
IMAGE_REF=$(grep -oE 'image:[[:space:]]*nginx:[0-9A-Za-z._-]+' "$SRC/docker-compose.yml" | head -1 | awk '{print $2}')
IMAGE_TAG="${IMAGE_REF##*:}"
UPSTREAM_TAG=$(printf '%s' "$IMAGE_TAG" | sed -E 's/^([0-9]+(\.[0-9]+)*).*$/\1/')
[ -n "$UPSTREAM_TAG" ] || { echo "FATAL: cannot read the image tag from $SRC/docker-compose.yml"; exit 1; }

VERSION="${1:-${UPSTREAM_TAG}-1}"
PLATFORM="${2:-x86_64}"

case "$PLATFORM" in
  x86_64|aarch64) : ;;
  *) echo "FATAL: platform must be x86_64 or aarch64 (got '$PLATFORM')"; exit 1 ;;
esac

# Version format: <upstream numeric version>-<packaging iteration>, e.g. 1.29.8-1.
# Never zero pad the iteration: the App Center compares version numbers
# segment by segment, so "-01" is not an upgrade over "-1".
case "$VERSION" in
  *-0|*-0[0-9]*)
    echo "FATAL: packaging iteration must not be zero padded (got '$VERSION')"; exit 1 ;;
esac
UPSTREAM="${VERSION%%-*}"
[ "$UPSTREAM" = "$UPSTREAM_TAG" ] || {
  echo "FATAL: compose image tag's version ($UPSTREAM_TAG) != upstream base of version ($UPSTREAM)"
  exit 1
}

echo ">> packaging ${APPID} version ${VERSION} platform ${PLATFORM} (image ${IMAGE_REF})"

# ------------------------------------------------------------------ stage ----
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE" "$OUT"
for f in config.ini "$APPID.lang" "$APPID.svg" docker-compose.yml; do
  cp "$SRC/$f" "$STAGE/$f"
done

python3 - "$SRC" "$STAGE" "$VERSION" "$PLATFORM" "$APPID" <<'PY'
import pathlib, sys
src, stage, ver, plat, appid = (pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]),
                                sys.argv[3], sys.argv[4], sys.argv[5])

# 1. version / platform placeholders
for name in ("config.ini", f"{appid}.lang"):
    p = stage / name
    data = p.read_text(encoding="utf-8").replace("@@VERSION@@", ver).replace("@@PLATFORM@@", plat)
    p.write_bytes(data.replace("\r\n", "\n").encode("utf-8"))

# 2. embed the entrypoint script.
#    docker compose interpolates ${VAR} and $VAR in compose files, so every '$'
#    in the inline script must be written '$$'; the YAML block scalar then
#    removes the eight spaces of block indentation again, so the script the
#    container receives is byte-identical to src/entrypoint.sh.
script = (src / "entrypoint.sh").read_text(encoding="utf-8")
if "$$" in script:
    sys.exit("FATAL: src/entrypoint.sh must not contain '$$' (it would survive escaping)")
escaped = script.replace("$", "$$")
indented = "\n".join(("        " + l) if l.strip() else "" for l in escaped.splitlines())
comp = stage / "docker-compose.yml"
text = comp.read_text(encoding="utf-8")
if "        @@ENTRYPOINT_SH@@" not in text:
    sys.exit("FATAL: docker-compose.yml is missing the indented @@ENTRYPOINT_SH@@ placeholder")
comp.write_text(text.replace("        @@ENTRYPOINT_SH@@", indented), encoding="utf-8")
print(f"   staged entrypoint: {len(script.splitlines())} lines, "
      f"{len(script)} bytes -> escaped into docker-compose.yml")
PY

# ---------------------------------------------------- build machine hygiene --
export COPYFILE_DISABLE=1
find "$STAGE" \( -name '._*' -o -name '.DS_Store' \) -delete
xattr -rc "$STAGE" 2>/dev/null || true
python3 - "$STAGE" <<'PY'
import sys, pathlib
for p in pathlib.Path(sys.argv[1]).rglob("*"):
    if p.is_file():
        b = p.read_bytes()
        if b.startswith(b"\xef\xbb\xbf"):
            b = b[3:]
        if b"\r\n" in b:
            b = b.replace(b"\r\n", b"\n")
        p.write_bytes(b)
PY

# ------------------------------------------------------- verify (hard gate) --
python3 - "$STAGE" "$VERSION" "$PLATFORM" "$APPID" "$IMAGE_REF" "$SRC" <<'PY'
import json, re, sys, pathlib, hashlib
import xml.etree.ElementTree as ET

stage, ver, plat, appid, image_ref, src = (pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3],
                                           sys.argv[4], sys.argv[5], pathlib.Path(sys.argv[6]))
errs = []
def chk(cond, msg):
    if not cond:
        errs.append(msg)

# ---- exactly the four required files at the archive root ----
names = sorted(p.name for p in stage.iterdir())
chk(names == sorted(["config.ini", f"{appid}.lang", f"{appid}.svg", "docker-compose.yml"]),
    f"archive must contain exactly 4 required files, got {names}")

# ---- config.ini -------------------------------------------------------------
raw_cfg = (stage / "config.ini").read_text(encoding="utf-8")
chk("@@" not in raw_cfg, "config.ini still contains an unreplaced @@PLACEHOLDER@@")
cfg = json.loads(raw_cfg)
chk(cfg["id"] == appid, "id must equal appid")
chk(cfg["version"] == ver, f"config.ini version must be {ver}")
chk(re.fullmatch(r"[0-9][0-9.]*-(?:[1-9][0-9]{0,2})", cfg["version"]) is not None,
    "version must be <digits.dots>-<iteration>, iteration >= 1 and not zero padded")
chk(cfg["application_type"] == "docker", "application_type must be docker")
chk("DockerEngine" in cfg["depend"], "depend must include DockerEngine")
chk("docker" in cfg["relation"] and "DockerEngine" in cfg["relation"],
    "relation must list docker + DockerEngine")
chk("type" not in cfg, "the iframe-only 'type' field must not appear (Docker apps use open_path)")
chk(cfg.get("open_path") is True, "open_path must be true")
chk(cfg["icon"] == f"/images/icons/{appid}.svg", "icon must be /images/icons/<appid>.svg")
chk(cfg["compose_project"] == appid, "compose_project must equal appid")
chk(cfg["platform"] == plat, f"config.ini platform must be {plat}")
chk(cfg.get("beta") is False, "beta must be false for a store submission")
chk(cfg.get("recommend") is False, "recommend must be false when submitting")
chk(cfg.get("publisher") == "Moechz", "publisher must be Moechz")
chk(cfg.get("user") not in ("", "root", None), "a dedicated non-root user must be set")
allowed = {"Audio_Video_Entertainment", "Photography_Video", "Backup_Sync", "Development_Tools",
           "Utilities", "Web_Services", "Security", "Download", "Driver", "Artificial_Intelligence"}
chk(isinstance(cfg.get("category"), list) and 1 <= len(cfg["category"]) <= 3,
    "category must be a list of 1..3 categories")
for c in cfg.get("category", []):
    chk(c in allowed, f"category '{c}' is not an official category id")
for field in ("id", "icon", "publisher", "exec", "version", "low_version", "category",
              "depend", "platform", "application_type", "user", "all_user_display",
              "allow_open_in_mobile", "path", "open_path", "name"):
    chk(field in cfg, f"required config.ini field missing: {field}")
m = re.fullmatch(r"http://\$\{ip\}:(\d+)", cfg["path"])
chk(m is not None, "path must be http://${ip}:<port> (Docker app URL form)")
cfg_port = int(m.group(1)) if m else 0
chk(not re.search(r"\d+\.\d+\.\d+\.\d+", json.dumps(cfg)), "config.ini must not contain a hardcoded IP")
for key in ("help", "official", "Official"):
    v = cfg.get(key)
    if v:
        chk(v.startswith("https://github.com/"),
            f"{key} must be a github.com URL (the link checker performs an HTTP GET)")

# ---- lang -------------------------------------------------------------------
lang = (stage / f"{appid}.lang").read_text(encoding="utf-8")
chk("@@" not in lang, "lang still contains an unreplaced @@PLACEHOLDER@@")
secs = re.findall(r"^\[([a-z]{2}-[a-z]{2})\]$", lang, re.M)
required14 = set("zh-cn zh-hk en-us fr-fr de-de it-it es-es hu-hu ja-jp ko-kr "
                 "pl-pl ru-ru tr-tr pt-pt".split())
chk(required14.issubset(set(secs)), f"lang missing required languages: {sorted(required14 - set(secs))}")
chk(len(secs) == len(set(secs)), "lang has duplicate language sections")
for s in secs:
    body = lang.split(f"[{s}]", 1)[1].split("[", 1)[0]
    for key in ("name", "auth", "version", "descript", "release_note", "important"):
        mm = re.search(rf'{key}\s*=\s*"(.+)"', body)
        chk(mm is not None and mm.group(1).strip(), f"[{s}] {key} empty or missing")
    d = re.search(r'descript\s*=\s*"(.+)"', body)
    chk(d is None or len(d.group(1)) <= 512, f"[{s}] descript longer than 512 chars")
    i = re.search(r'important\s*=\s*"(.+)"', body)
    chk(i is None or len(i.group(1)) <= 512, f"[{s}] important longer than 512 chars")
    chk(f'version      = "{ver}"' in body, f"[{s}] version != {ver}")
chk(re.search(r"\bbeta\b", lang, re.I) is None, "lang must not contain the word 'beta' (V11)")

# ---- svg icon (TOS Icon Compliance: <= 50 KB, <= 50 elements) ---------------
svg_path = stage / f"{appid}.svg"
svg_bytes = svg_path.read_bytes()
chk(len(svg_bytes) <= 50 * 1024, f"icon too large: {len(svg_bytes)} bytes (limit 50 KB)")
svg_txt = svg_bytes.decode("utf-8")
try:
    root = ET.fromstring(svg_txt)
    n_elems = sum(1 for _ in root.iter())
    chk(root.tag.endswith("svg"), "icon root element must be <svg>")
    chk("viewBox" in root.attrib, "icon svg must declare viewBox")
    chk(n_elems <= 50, f"icon has {n_elems} elements (limit 50)")
except ET.ParseError as e:
    errs.append(f"icon is not valid XML: {e}")
    n_elems = -1
for banned in ("<filter", "<use", "sodipodi", "inkscape", "<metadata", "rdf:"):
    chk(banned not in svg_txt, f"icon must not contain {banned}")

# ---- docker-compose.yml -----------------------------------------------------
comp = (stage / "docker-compose.yml").read_text(encoding="utf-8")
comp_nc = "\n".join(l for l in comp.splitlines() if not l.lstrip().startswith("#"))
for banned in ("privileged", "network_mode", "docker.sock", "cap_add", "pid:", "ipc:"):
    chk(banned not in comp_nc, f"compose must not use {banned}")
chk(re.search(r"ghcr\.io|quay\.io|lscr\.io|registry\.", comp_nc) is None,
    "images must come from Docker Hub (bare names)")
chk(":latest" not in comp_nc, "image must use a fixed tag, never :latest")
chk(f"image: {image_ref}" in comp_nc, f"compose must pull exactly {image_ref}")
upstream = ver.split("-")[0]
chk(re.search(rf"image:\s*nginx:{re.escape(upstream)}([.\-][0-9A-Za-z._-]*)?\s*$", comp_nc, re.M) is not None,
    f"image tag must be the upstream version {upstream} (with an optional variant suffix)")
chk(re.search(rf"container_name:\s*{appid}\s*$", comp_nc, re.M) is not None,
    "main container_name must equal appid")
services = comp_nc.count("container_name:")
chk(services >= 1, "expected at least one service")
chk(comp_nc.count('user: "1000:1000"') == services, "every service must pin non-root user 1000:1000")
chk(comp_nc.count("restart: unless-stopped") == services, "every service must use restart: unless-stopped")
chk(comp_nc.count("healthcheck:") == services, "every service must define a healthcheck")
chk(len(re.findall(r"^\s+TZ:\s*\S", comp_nc, re.M)) == services, "every service must set TZ explicitly")
chk(re.search(r"user:\s*[\"']?(0|root)", comp_nc) is None, "containers must not run as root")
chk("TZ: Asia/Shanghai" in comp_nc, "TZ must default to Asia/Shanghai")
# data must live below the application data root, and never use the /Volume*
# wildcard (the platform does not expand it - it creates a literal /Volume*)
vols = re.findall(r"^\s*-\s*(/[^:\s]+):(/[^:\s]+)\s*$", comp_nc, re.M)
chk(len(vols) >= 1, "at least one persistent volume mount is required")
for host, cont in vols:
    chk(host.startswith(f"/Volume1/DockerAppData/{appid}/"),
        f"volume source {host} must be below /Volume1/DockerAppData/{appid}/")
chk("/Volume*" not in comp_nc, "never use the /Volume* wildcard (the platform does not expand it)")
chk("./" not in "\n".join(re.findall(r"^\s*-\s*(.*)$", comp_nc, re.M)),
    "relative './' volume mounts must not be used")
chk(comp_nc.rstrip().endswith("protocol: http"), "x-app-meta must be the last block")
chk("x-app-meta:" in comp_nc and f"port: {cfg_port}" in comp_nc,
    "x-app-meta web.port must match the config.ini path port")
ports = re.findall(r"^\s*-\s*[\"'](\d+):(\d+)[\"']\s*$", comp_nc, re.M)
chk(len(ports) == 1, f"compose must publish exactly one host port, got {ports}")
if len(ports) == 1:
    host, cont = int(ports[0][0]), int(ports[0][1])
    chk(host == cfg_port, f"published host port {host} != config.ini path port {cfg_port}")
    reserved = (22, 80, 443, 445, 3306, 5050, 5432, 6379, 8181, 8443)
    chk(host not in reserved, f"host port {host} is reserved by TOS")
    chk(8000 <= host <= 19999, f"host port {host} outside the TOS-recommended 8000-19999 range")
    chk(cont == 8080, f"container port should be 8080, got {cont}")
# no literal secrets anywhere in the compose
for pat, msg in ((r"(?i)(PASSWORD|SECRET|TOKEN|API_KEY):\s*\S", "compose must not contain a literal secret"),
                 (r"(?i)user:\s*[\"']?root", "compose must not run as root")):
    chk(re.search(pat, comp_nc) is None, msg)
chk("curl -s -o /dev/null http://127.0.0.1:8080/" in comp_nc,
    "healthcheck must probe the published container port")
# every '$' in a compose file is subject to ${VAR} interpolation: only '$$' is
# safe (an unescaped ${HOME} is replaced by the *host's* home directory)
bad_dollars = re.findall(r"(?<!\$)\$\{?[A-Za-z_]", comp_nc)
chk(not bad_dollars, f"unescaped '$' in compose (must be '$$'): {sorted(set(bad_dollars))}")
chk('entrypoint: ["/bin/sh", "-c"]' in comp_nc, "the entrypoint wrapper must be installed")
# The official TOSAppSelfTestingTool parses the compose line by line: a comment
# line directly in front of a "- value" sequence item makes it skip the
# permission sync, so the bind-mounted data directories stay root-owned and the
# non-root container cannot write into them (D-006). Keep list blocks clean.
bad_seq = re.search(r"^([ \t]*)#[^\n]*\n\1-[ \t]", comp, re.M)
chk(bad_seq is None,
    "no comment may sit directly in front of a '- value' item: "
    f"{bad_seq.group(0).strip()[:60] if bad_seq else ''}")

# ---- the embedded entrypoint must match src/entrypoint.sh exactly ----------
_m = re.search(r"^    command:\n      - \|\n(.*?)\n(?=^    [a-z_]+:)", comp, re.S | re.M)
chk(_m is not None, "compose must embed the entrypoint under 'command:'")
if _m:
    block = _m.group(1)
    lines = [l[8:] if l.startswith(" " * 8) else l for l in block.splitlines()]
    embedded = "\n".join(lines) + "\n"
    source = (src / "entrypoint.sh").read_text(encoding="utf-8")
    chk("$$" not in source, "src/entrypoint.sh must not contain '$$'")
    expected = source.replace("$", "$$")
    chk(embedded == expected, "embedded entrypoint differs from src/entrypoint.sh")
    chk("set -u" in embedded, "entrypoint must keep 'set -u'")
    chk("nginx -t -c" in embedded, "entrypoint must validate the configuration before starting")
    chk("exec nginx -c" in embedded, "entrypoint must exec nginx in the foreground")
    # locations.conf must be included exactly once, inside the default server;
    # an extra include at http level makes every "location" in it a fatal
    # "directive is not allowed here" error (D-008)
    chk(embedded.count("include @CONF_DIR@/locations.conf;") == 1,
        "locations.conf must be included exactly once (inside the default server)")

if errs:
    print("VERIFY FAIL:")
    for e in errs:
        print("  -", e)
    sys.exit(1)
print(f"verify OK: files={names} langs={len(secs)} icon_elements={n_elems} "
      f"icon_bytes={len(svg_bytes)} host_port={cfg_port} volumes={len(vols)}")
PY

# ------------------------------------------------------------------- pack ----
# GNU-format tar, deterministic ownership/timestamps; deterministic gzip.
python3 - "$STAGE" "$OUT" "$APPID" <<'PY'
import tarfile, pathlib, gzip, io, sys
stage, out, appid = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
tarpath = out / f"{appid}.tar.gz"
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
    for p in sorted(stage.iterdir()):
        ti = tf.gettarinfo(str(p), arcname=p.name)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = 0
        ti.mode = 0o644
        with open(p, "rb") as fh:
            tf.addfile(ti, fh)
with open(tarpath, "wb") as fh:
    with gzip.GzipFile(fileobj=fh, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(buf.getvalue())
print("packed", tarpath, f"{tarpath.stat().st_size} bytes")
PY

python3 - "$OUT" "$APPID" <<'PY'
import hashlib, pathlib, sys
out, appid = pathlib.Path(sys.argv[1]), sys.argv[2]
p = out / f"{appid}.tar.gz"
h = hashlib.sha256(p.read_bytes()).hexdigest()
(out / f"{appid}.tar.gz.sha256").write_text(f"{h}  {appid}.tar.gz\n")
print(f"{h}  {appid}.tar.gz")
PY

# ------------------------------------------- copy for manual compose testing -
mkdir -p "$ROOT/test/compose-resolved"
cp "$STAGE/docker-compose.yml" "$ROOT/test/compose-resolved/docker-compose.yml"

echo ">> done:"
ls -la "$OUT"
