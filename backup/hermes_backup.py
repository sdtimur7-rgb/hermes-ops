#!/usr/bin/env python3
"""Бэкап серверного Hermes: открытый снимок + зашифрованное хранилище.

Всё, что владелец делает с Hermes через Telegram (навыки, память, дежурные задачи,
настройки), живёт только на сервере. Этот инструмент снимает с него две копии:

  snapshot  — открытый снимок навыков, памяти, задач и настроек с вычищенными
              секретами. Ложится в git с историей: видно, что и когда поменялось.
  vault     — полный архив со всем, что нужно для восстановления: .env, auth.json,
              базы (целостные копии через sqlite3.backup), тот же снимок без чистки.
              Шифруется открытым ключом владельца; закрытый ключ есть только на Mac.
  decrypt   — обратная операция на Mac.

Шифрование гибридное: случайный 64-байтный секрет оборачивается RSA-OAEP(SHA-256),
данные — AES-256-CTR, целостность — HMAC-SHA256 поверх заголовка и шифротекста
(encrypt-then-MAC). Нужна только библиотека cryptography — она уже есть в venv Hermes.
"""
import argparse
import hashlib
import hmac
import io
import json
import math
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

MAGIC = b"HBK1"
CHUNK = 1 << 20
PART_BYTES = 45 * 1024 * 1024          # GitHub режет файлы больше 100 МБ, предупреждает с 50

# Что составляет «работу владельца». Коды Hermes, кэши, логи и venv сюда не входят:
# они восстанавливаются установкой, а место в бэкапе съедают сотнями мегабайт.
TEXT_ITEMS = [
    "skills", "memories", "scripts", "hooks", "plugins", "state", "kanban/boards",
    "SOUL.md", "config.yaml", "cron/jobs.json", "channel_directory.json",
    "webhook_subscriptions.json",
]
SECRET_FILES = [".env", "auth.json"]
DATABASES = [
    "state.db", "cron/executions.db", "cron/notepad.db", "projects.db", "response_store.db",
    "memory_store.db", "verification_evidence.db", "kanban.db",
]
SKIP_DIRS = {"__pycache__", ".git", "node_modules", ".venv", "venv", ".cache"}
MAX_TEXT_FILE = 5 * 1024 * 1024

REDACTED = "<скрыто>"
TOKEN_PATTERNS = [
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"\bpub_(?:sk|whsec)_[A-Za-z0-9_-]{8,}"),
    re.compile(r"\bsk-(?:or-v1-|ant-|proj-)?[A-Za-z0-9_-]{20,}"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}"),
    re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}\b"),                     # токен Telegram-бота
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
]
# «ключ: значение», где имя говорит о секрете. Значение вычищаем, только если оно само
# похоже на ключ: длинное, с буквами и цифрами, с высокой энтропией. Иначе рвётся код
# навыков (`password=args.password`) и документация (`secret: "your-secret"`).
ASSIGN_PATTERN = re.compile(
    r"(?i)((?:api[_-]?key|secret|token|password|passwd|authorization)\w*[\"']?\s*[:=]\s*[\"']?(?:Bearer\s+)?)"
    r"([A-Za-z0-9_\-./+=]{16,})")


def looks_like_secret(value: str) -> bool:
    if not (re.search(r"\d", value) and re.search(r"[A-Za-z]", value)):
        return False
    counts = {ch: value.count(ch) for ch in set(value)}
    entropy = -sum(n / len(value) * math.log2(n / len(value)) for n in counts.values())
    return entropy >= 3.5


def redact(text: str) -> tuple[str, int]:
    count = 0
    for pattern in TOKEN_PATTERNS:
        text, n = pattern.subn(REDACTED, text)
        count += n
    hits = 0

    def replace(match):
        nonlocal hits
        if not looks_like_secret(match.group(2)):
            return match.group(0)
        hits += 1
        return match.group(1) + REDACTED

    text = ASSIGN_PATTERN.sub(replace, text)
    return text, count + hits


def is_binary(data: bytes) -> bool:
    return b"\x00" in data[:8192]


def iter_files(root: Path):
    if root.is_file():
        yield root
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            path = Path(dirpath) / name
            if not path.is_symlink():
                yield path


# --- открытый снимок ---------------------------------------------------------

def cmd_snapshot(home: Path, out: Path, system: bool = True) -> int:
    """Перезаписывает содержимое out (кроме .git) снимком home с вычищенными секретами."""
    out.mkdir(parents=True, exist_ok=True)
    for child in out.iterdir():
        if child.name in (".git", "README.md"):
            continue
        shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
    files = redactions = skipped = 0
    for item in TEXT_ITEMS:
        src = home / item
        if not src.exists():
            continue
        for path in iter_files(src):
            rel = path.relative_to(home)
            dst = out / rel
            try:
                if path.stat().st_size > MAX_TEXT_FILE:
                    skipped += 1
                    continue
                data = path.read_bytes()
            except OSError:
                skipped += 1
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            if is_binary(data):
                dst.write_bytes(data)
            else:
                text, n = redact(data.decode("utf-8", errors="replace"))
                redactions += n
                dst.write_text(text, encoding="utf-8")
            files += 1
    for name, content in (collect_system_info() if system else {}).items():
        dst = out / "system" / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(redact(content)[0], encoding="utf-8")
    (out / "SNAPSHOT.json").write_text(json.dumps({
        "files": files, "redactions": redactions, "skipped_large_or_unreadable": skipped,
        "hermes_home": str(home),
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"снимок: {files} файлов, вычищено секретов: {redactions}, пропущено: {skipped}")
    return 0


def collect_system_info() -> dict:
    """То, что живёт вне ~/.hermes, но без чего сервер не восстановить: cron и службы."""
    info = {}
    try:
        crontab = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=10)
        if crontab.returncode == 0:
            info["crontab.txt"] = crontab.stdout
    except (OSError, subprocess.SubprocessError):
        pass
    for base in (Path("/etc/systemd/system"), Path.home() / ".config/systemd/user"):
        if not base.is_dir():
            continue
        for unit in sorted(base.glob("*")):
            if unit.is_file() and re.search(r"hermes|cloudflared|publicia", unit.name, re.I):
                try:
                    info[f"systemd/{unit.name}"] = unit.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    pass
    # Самодельные скрипты рядом с домашним каталогом (приёмники, туннели) — их часто
    # заводит сам Hermes, и больше нигде они не записаны.
    user_home = Path.home()
    for path in sorted(user_home.glob("*")) + sorted(user_home.glob("*/*")):
        rel = path.relative_to(user_home)
        if (rel.parts[0].startswith(".") or rel.parts[0] in ("ops", "hermes-backup", "hermes-backup-vault")
                or any(p in SKIP_DIRS for p in rel.parts)):
            continue
        if path.is_file() and path.suffix in (".py", ".sh", ".js", ".mjs", ".service", ".yaml", ".yml", ".json", ".toml") \
                and path.stat().st_size < 512 * 1024:
            try:
                info["home/" + str(rel)] = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                pass
    return info


# --- хранилище ---------------------------------------------------------------

def copy_database(src: Path, dst: Path) -> str:
    """Целостная копия живой базы. Файлы -wal/-shm отдельно копировать бессмысленно."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        source = sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=10)
        target = sqlite3.connect(str(dst))
        with target:
            source.backup(target, pages=4096, sleep=0.05)
        source.close()
        target.close()
        return "sqlite-backup"
    except sqlite3.Error as exc:
        shutil.copy2(src, dst)
        return f"копия файла ({exc})"


def build_vault_tar(home: Path, tar_path: Path, system: bool = True) -> dict:
    report = {"files": 0, "databases": {}, "secrets": []}
    with tempfile.TemporaryDirectory(prefix="hermes-vault-") as staging_dir:
        staging = Path(staging_dir)
        for item in TEXT_ITEMS + SECRET_FILES:
            src = home / item
            if not src.exists():
                continue
            for path in iter_files(src):
                dst = staging / "hermes" / path.relative_to(home)
                dst.parent.mkdir(parents=True, exist_ok=True)
                try:
                    shutil.copy2(path, dst)
                    report["files"] += 1
                except OSError:
                    pass
            if item in SECRET_FILES:
                report["secrets"].append(item)
        for rel in DATABASES:
            src = home / rel
            if src.exists():
                report["databases"][rel] = copy_database(src, staging / "hermes" / rel)
        for name, content in (collect_system_info() if system else {}).items():
            dst = staging / "system" / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(content, encoding="utf-8")
        (staging / "VAULT.json").write_text(json.dumps(
            {**report, "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
             "hermes_home": str(home)}, ensure_ascii=False, indent=2), encoding="utf-8")
        with tarfile.open(tar_path, "w:gz", compresslevel=6) as tar:
            tar.add(staging, arcname="hermes-vault")
    return report


def encrypt_file(src: Path, dst: Path, public_pem: bytes) -> None:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    public_key = serialization.load_pem_public_key(public_pem)
    secret = os.urandom(64)
    wrapped = public_key.encrypt(secret, padding.OAEP(
        mgf=padding.MGF1(algorithm=hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
    nonce = os.urandom(16)
    header = MAGIC + len(wrapped).to_bytes(2, "big") + wrapped + nonce
    mac = hmac.new(secret[32:], header, hashlib.sha256)
    encryptor = Cipher(algorithms.AES(secret[:32]), modes.CTR(nonce)).encryptor()
    with src.open("rb") as fin, dst.open("wb") as fout:
        fout.write(header)
        while chunk := fin.read(CHUNK):
            block = encryptor.update(chunk)
            mac.update(block)
            fout.write(block)
        tail = encryptor.finalize()
        mac.update(tail)
        fout.write(tail)
        fout.write(mac.digest())


def decrypt_file(src: Path, dst: Path, private_pem: bytes) -> None:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    private_key = serialization.load_pem_private_key(private_pem, password=None)
    size = src.stat().st_size
    with src.open("rb") as fin:
        if fin.read(4) != MAGIC:
            raise ValueError("это не архив hermes_backup (нет сигнатуры HBK1)")
        wrapped_len = int.from_bytes(fin.read(2), "big")
        wrapped = fin.read(wrapped_len)
        nonce = fin.read(16)
        secret = private_key.decrypt(wrapped, padding.OAEP(
            mgf=padding.MGF1(algorithm=hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
        header_len = 4 + 2 + wrapped_len + 16
        body_len = size - header_len - 32
        # Первый проход — проверка целостности: расшифровывать испорченное нельзя.
        mac = hmac.new(secret[32:], MAGIC + wrapped_len.to_bytes(2, "big") + wrapped + nonce, hashlib.sha256)
        remaining = body_len
        while remaining:
            block = fin.read(min(CHUNK, remaining))
            mac.update(block)
            remaining -= len(block)
        if not hmac.compare_digest(mac.digest(), fin.read(32)):
            raise ValueError("архив повреждён или подменён: подпись HMAC не сошлась")
        fin.seek(header_len)
        decryptor = Cipher(algorithms.AES(secret[:32]), modes.CTR(nonce)).decryptor()
        remaining = body_len
        with dst.open("wb") as fout:
            while remaining:
                block = fin.read(min(CHUNK, remaining))
                fout.write(decryptor.update(block))
                remaining -= len(block)
            fout.write(decryptor.finalize())


def split_file(path: Path, out_dir: Path, base: str) -> list:
    out_dir.mkdir(parents=True, exist_ok=True)
    parts = []
    with path.open("rb") as fin:
        index = 0
        while True:
            data = fin.read(PART_BYTES)
            if not data:
                break
            part = out_dir / f"{base}.part{index:03d}"
            part.write_bytes(data)
            parts.append(part)
            index += 1
    return parts


def cmd_vault(home: Path, pubkey: Path, out_dir: Path, system: bool = True) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("vault.hbk.part*"):
        old.unlink()
    with tempfile.TemporaryDirectory(prefix="hermes-vault-out-") as tmp:
        tar_path = Path(tmp) / "vault.tar.gz"
        report = build_vault_tar(home, tar_path, system)
        enc_path = Path(tmp) / "vault.hbk"
        encrypt_file(tar_path, enc_path, pubkey.read_bytes())
        parts = split_file(enc_path, out_dir, "vault.hbk")
        size_mb = enc_path.stat().st_size / 1048576
    (out_dir / "VAULT.json").write_text(json.dumps({
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "parts": [p.name for p in parts], "size_mb": round(size_mb, 1),
        "files": report["files"], "databases": report["databases"], "secrets": report["secrets"],
        "sha256_parts": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in parts},
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"хранилище: {size_mb:.1f} МБ в {len(parts)} частях, файлов {report['files']}, "
          f"баз {len(report['databases'])}, секреты: {', '.join(report['secrets']) or 'нет'}")
    return 0


def cmd_decrypt(parts_dir: Path, privkey: Path, out: Path) -> int:
    parts = sorted(parts_dir.glob("vault.hbk.part*"))
    if not parts:
        print(f"в {parts_dir} нет частей vault.hbk.part*", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory(prefix="hermes-vault-dec-") as tmp:
        joined = Path(tmp) / "vault.hbk"
        with joined.open("wb") as fout:
            for part in parts:
                fout.write(part.read_bytes())
        decrypt_file(joined, out, privkey.read_bytes())
    print(f"расшифровано: {out} ({out.stat().st_size / 1048576:.1f} МБ). "
          f"Распаковать: tar -xzf {out.name}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("snapshot"); p.add_argument("--home", required=True); p.add_argument("--out", required=True)
    p.add_argument("--no-system", action="store_true", help="не собирать cron, службы и скрипты домашнего каталога")
    p = sub.add_parser("vault"); p.add_argument("--home", required=True); p.add_argument("--pubkey", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--no-system", action="store_true", help="не собирать cron, службы и скрипты домашнего каталога")
    p = sub.add_parser("decrypt"); p.add_argument("--parts", required=True); p.add_argument("--privkey", required=True)
    p.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.cmd == "snapshot":
        return cmd_snapshot(Path(args.home).expanduser(), Path(args.out).expanduser(), not args.no_system)
    if args.cmd == "vault":
        return cmd_vault(Path(args.home).expanduser(), Path(args.pubkey).expanduser(), Path(args.out).expanduser(),
                         not args.no_system)
    return cmd_decrypt(Path(args.parts).expanduser(), Path(args.privkey).expanduser(), Path(args.out).expanduser())


if __name__ == "__main__":
    sys.exit(main())
