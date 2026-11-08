#!/usr/bin/env python3
"""Resolve and download FreeBSD packages on a non-FreeBSD build host (stdlib + curl + tar).

pkg(8) is a FreeBSD binary and cannot run on the Debian hub, so build.sh asks this script
for the verified .pkg files and unpacks them into the image tree itself.

  pkg-fetch.py --wanted packages.txt --cache DIR --keys DIR --out resolved.txt \
      [--abi FreeBSD:15:amd64] [--branch quarterly] [--mirrors "URL URL"] [--refresh]

What it does (same trust chain as pkg(8)):
  1. fetch <mirror>/<abi>/<branch>/packagesite.pkg (the catalog), unpack packagesite.yaml,
     .sig and .pub; the .pub fingerprint (sha256) must be listed in --keys (the
     /usr/share/keys/pkg/trusted of the FreeBSD tree) and the RSA signature over the
     sha256 hex digest of packagesite.yaml must verify. The mirror is therefore untrusted.
  2. dependency closure of the wanted names (catalog "deps").
  3. download every package into the cache, check size and checksum (blake2b, as pkg(8)) against the catalog.
The catalog is cached; it is only fetched again with --refresh (PKG_REFRESH=1), so a rebuild
with unchanged inputs resolves to the same versions. Output: one line per package,
"name version sum path-of-the-.pkg-file", in install order independent of dependencies.
"""
import argparse, hashlib, json, os, re, subprocess, sys, tempfile, shutil

UA = "simple-pxe-pkg-fetch/1"


def die(msg):
    print(f"pkg-fetch: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg):
    print(f"pkg-fetch: {msg}", file=sys.stderr)


def curl(url, dest):
    r = subprocess.run(["curl", "-fsSL", "--retry", "3", "--retry-delay", "3", "--connect-timeout", "15",
                        "--max-time", "900", "-A", UA, "-o", dest, url])
    return r.returncode == 0


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


ZB32 = "ybndrfg8ejkmcpqxot1uwisza345h769"


def pkg_sum(path):
    """The catalog's "sum": "2$" + blake2b-512 of the file in pkg(8)'s base32 (z-base-32 alphabet, least significant bits first)."""
    h = hashlib.blake2b(digest_size=64)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    n = int.from_bytes(h.digest(), "little")
    out = [ZB32[(n >> i) & 31] for i in range(0, 512, 5)]
    return "2$" + "".join(out)


def trusted_fingerprints(keydir):
    fps = set()
    for name in os.listdir(keydir):
        m = re.search(r'fingerprint:\s*"([0-9a-f]{64})"', open(os.path.join(keydir, name)).read())
        if m:
            fps.add(m.group(1))
    if not fps:
        die(f"no trusted fingerprints in {keydir}")
    return fps


def verify_catalog(cdir, keydir):
    y, sig, pub = (os.path.join(cdir, n) for n in ("packagesite.yaml", "packagesite.yaml.sig", "packagesite.yaml.pub"))
    if sha256_file(pub) not in trusted_fingerprints(keydir):
        die("catalog signing key is not in the trusted FreeBSD key directory")
    digest = sha256_file(y)
    with tempfile.TemporaryDirectory() as t:
        key, msg = os.path.join(t, "k.pem"), os.path.join(t, "digest")
        subprocess.run(["openssl", "pkey", "-pubin", "-in", pub, "-out", key], check=True)
        with open(msg, "w") as f:
            f.write(digest)
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", key, "-signature", sig, msg],
                           capture_output=True, text=True)
    if r.returncode != 0:
        die("catalog signature does not verify")


def fetch_catalog(cdir, repo_urls, refresh):
    need = refresh or not all(os.path.exists(os.path.join(cdir, n)) for n in
                              ("packagesite.yaml", "packagesite.yaml.sig", "packagesite.yaml.pub"))
    if not need:
        return
    os.makedirs(cdir, exist_ok=True)
    for base in repo_urls:
        with tempfile.TemporaryDirectory(dir=cdir) as t:
            pkgf = os.path.join(t, "packagesite.pkg")
            log(f"fetching catalog {base}/packagesite.pkg")
            if not curl(f"{base}/packagesite.pkg", pkgf):
                log("  failed, next mirror")
                continue
            subprocess.run(["tar", "--zstd", "-xf", pkgf, "-C", t], check=True)
            for n in ("packagesite.yaml", "packagesite.yaml.sig", "packagesite.yaml.pub"):
                if not os.path.exists(os.path.join(t, n)):
                    die(f"catalog from {base} lacks {n}")
            for n in ("packagesite.yaml", "packagesite.yaml.sig", "packagesite.yaml.pub"):
                os.replace(os.path.join(t, n), os.path.join(cdir, n + ".new"))
        for n in ("packagesite.yaml", "packagesite.yaml.sig", "packagesite.yaml.pub"):
            os.replace(os.path.join(cdir, n + ".new"), os.path.join(cdir, n))
        open(os.path.join(cdir, "source"), "w").write(base + "\n")
        return
    die("could not fetch the catalog from any mirror")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wanted", required=True)
    ap.add_argument("--cache", required=True)
    ap.add_argument("--keys", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--abi", default="FreeBSD:15:amd64")
    ap.add_argument("--branch", default="quarterly")
    ap.add_argument("--mirrors", default="https://mirrors.aliyun.com/freebsd-pkg https://pkg.freebsd.org")
    ap.add_argument("--refresh", action="store_true")
    a = ap.parse_args()

    wanted = []
    for line in open(a.wanted):
        line = line.split("#", 1)[0].strip()
        if line:
            wanted.append(line)
    if not wanted:
        die(f"no packages in {a.wanted}")

    repos = [f"{m.rstrip('/')}/{a.abi}/{a.branch}" for m in a.mirrors.split()]
    cdir = os.path.join(a.cache, f"{a.abi.replace(':', '-')}-{a.branch}")
    fetch_catalog(cdir, repos, a.refresh)
    verify_catalog(cdir, a.keys)

    catalog = {}
    with open(os.path.join(cdir, "packagesite.yaml")) as f:
        for line in f:
            d = json.loads(line)
            catalog[d["name"]] = d

    closure = {}

    def add(name, why):
        if name in closure:
            return
        d = catalog.get(name)
        if d is None:
            die(f"package '{name}' ({why}) is not in the {a.abi}/{a.branch} repository")
        if d["abi"] not in (a.abi, re.sub(r"[^:]+$", "*", a.abi)):
            die(f"{name}: ABI {d['abi']} does not match {a.abi}")
        closure[name] = d
        for dep in d.get("deps", {}):
            add(dep, f"dependency of {name}")

    for w in wanted:
        add(w, "listed in " + os.path.basename(a.wanted))

    pdir = os.path.join(cdir, "All")
    os.makedirs(pdir, exist_ok=True)
    total = fetched = 0
    lines = []
    for name in sorted(closure):
        d = closure[name]
        fn = os.path.join(pdir, os.path.basename(d["path"]))
        total += d["pkgsize"]
        if not (os.path.exists(fn) and os.path.getsize(fn) == d["pkgsize"] and pkg_sum(fn) == d["sum"]):
            ok = False
            for base in repos:
                tmp = fn + ".part"
                if curl(f"{base}/{d['path']}", tmp) and os.path.getsize(tmp) == d["pkgsize"] \
                        and pkg_sum(tmp) == d["sum"]:
                    os.replace(tmp, fn)
                    ok = True
                    fetched += d["pkgsize"]
                    break
                if os.path.exists(tmp):
                    os.remove(tmp)
            if not ok:
                die(f"could not download a valid {d['path']} (gone from the mirror? try PKG_REFRESH=1)")
        lines.append(f"{name} {d['version']} {d['sum']} {fn}")

    tmpo = a.out + ".tmp"
    with open(tmpo, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmpo, a.out)
    log(f"{len(closure)} packages ({len(wanted)} wanted), {total / 1e6:.1f} MB compressed, "
        f"{sum(d['flatsize'] for d in closure.values()) / 1e6:.1f} MB installed, "
        f"{fetched / 1e6:.1f} MB downloaded this run; cache {cdir}")


if __name__ == "__main__":
    main()
