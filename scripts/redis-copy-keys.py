#!/usr/bin/env python3
"""Логическое копирование ключей Redis → Valkey (или в обратную сторону) командами по типам.

Зачем: RDB Redis 7.4+/8.x (формат v12) Valkey не читает («Can't handle RDB format version 12»),
поэтому ни replicaof, ни RDB-restore, ни DUMP/RESTORE между ними не работают. Скрипт читает
каждый ключ типизированными командами и пишет их на приёмник, сохраняя TTL, затем сверяет
содержимое ключ-в-ключ.

Типы: string, hash, list, set, zset, stream, ReJSON-RL (JSON.GET/SET). Иной тип — ошибка
(ничего не пропускается молча).

Адреса — только через env (пароли не светятся в ps/истории):
  SRC_URL=redis://default:<pw>@127.0.0.1:16379  DST_URL=redis://default:<pw>@127.0.0.1:16380

  uv run -q --with 'redis>=5' python -I scripts/redis-copy-keys.py [--dbs 0,1,3] [--dry-run] [--verify-only]
      [--allow-nonempty]

--dbs по умолчанию — все непустые БД источника (INFO keyspace).
Приёмник должен быть пуст в копируемых БД (иначе отказ без --allow-nonempty).
Выход: 0 — скопировано и сверено, 1 — расхождения/ошибки, 2 — неверный вызов.
"""
import argparse
import os
import sys

try:
    import redis
except ImportError:  # pragma: no cover
    sys.exit("✗ нужен пакет redis: uv run -q --with 'redis>=5' python -I scripts/redis-copy-keys.py")

BATCH = 500


def connect(url, db):
    return redis.Redis.from_url(url, db=db, decode_responses=False, socket_timeout=30)


def nonempty_dbs(r):
    ks = r.info("keyspace")
    return sorted(int(k[2:]) for k, v in ks.items() if k.startswith("db") and v.get("keys", 0) > 0)


def read_key(r, key, typ):
    if typ == b"string":
        return r.get(key)
    if typ == b"hash":
        return r.hgetall(key)
    if typ == b"list":
        return r.lrange(key, 0, -1)
    if typ == b"set":
        return sorted(r.smembers(key))
    if typ == b"zset":
        return r.zrange(key, 0, -1, withscores=True)
    if typ == b"stream":
        return r.xrange(key, "-", "+")
    if typ == b"ReJSON-RL":
        return r.execute_command("JSON.GET", key, "$")
    raise ValueError(f"неподдерживаемый тип {typ!r}")


def write_key(w, key, typ, val):
    if typ == b"string":
        w.set(key, val)
    elif typ == b"hash":
        w.hset(key, mapping=val)
    elif typ == b"list":
        w.rpush(key, *val)
    elif typ == b"set":
        w.sadd(key, *val)
    elif typ == b"zset":
        w.zadd(key, {m: s for m, s in val})
    elif typ == b"stream":
        for entry_id, fields in val:
            w.xadd(key, fields, id=entry_id)
    elif typ == b"ReJSON-RL":
        # JSON.GET key $ возвращает массив из одного документа: "[{...}]" → берём элемент.
        doc = val.decode() if isinstance(val, bytes) else val
        inner = doc.strip()
        if inner.startswith("[") and inner.endswith("]"):
            inner = inner[1:-1]
        w.execute_command("JSON.SET", key, "$", inner)
    else:
        raise ValueError(f"неподдерживаемый тип {typ!r}")


def scan_keys(r):
    return list(r.scan_iter(count=BATCH))


def copy_db(src_url, dst_url, db, dry_run, allow_nonempty):
    src, dst = connect(src_url, db), connect(dst_url, db)
    if not allow_nonempty and dst.dbsize() > 0 and not dry_run:
        print(f"  ✗ db{db}: приёмник не пуст ({dst.dbsize()} ключей) — нужен --allow-nonempty", file=sys.stderr)
        return 1
    keys, copied, expired, errors = scan_keys(src), 0, 0, 0
    for key in keys:
        typ = src.type(key)
        if typ == b"none":
            expired += 1  # истёк между SCAN и TYPE
            continue
        pttl = src.pttl(key)
        try:
            val = read_key(src, key, typ)
            if val is None:
                expired += 1
                continue
            if not dry_run:
                dst.delete(key)
                write_key(dst, key, typ, val)
                if pttl and pttl > 0:
                    dst.pexpire(key, pttl)
            copied += 1
        except Exception as e:  # noqa: BLE001 — сообщаем и считаем, не роняем весь прогон
            errors += 1
            print(f"  ✗ db{db} {key!r} ({typ.decode()}): {e}", file=sys.stderr)
    verb = "к копированию" if dry_run else "скопировано"
    print(f"  db{db}: {verb} {copied}, истекло по ходу {expired}, ошибок {errors}")
    return 1 if errors else 0


def verify_db(src_url, dst_url, db):
    src, dst = connect(src_url, db), connect(dst_url, db)
    diff = 0
    for key in scan_keys(src):
        typ = src.type(key)
        if typ == b"none":
            continue
        try:
            a = read_key(src, key, typ)
            if dst.type(key) != typ:
                raise AssertionError(f"тип на приёмнике {dst.type(key)!r}")
            b = read_key(dst, key, typ)
            if a != b:
                raise AssertionError("значение отличается")
            if (src.pttl(key) > 0) != (dst.pttl(key) > 0):
                raise AssertionError("TTL: у одной стороны есть, у другой нет")
        except Exception as e:  # noqa: BLE001
            diff += 1
            print(f"  ✗ verify db{db} {key!r}: {e}", file=sys.stderr)
    ns, nd = src.dbsize(), dst.dbsize()
    mark = "✓" if diff == 0 and ns == nd else "✗"
    print(f"  {mark} verify db{db}: src={ns} dst={nd} расхождений {diff}")
    return 0 if diff == 0 and ns == nd else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dbs", help="список БД через запятую (по умолчанию — непустые на источнике)")
    ap.add_argument("--dry-run", action="store_true", help="только посчитать, ничего не писать")
    ap.add_argument("--verify-only", action="store_true", help="только сверить источник и приёмник")
    ap.add_argument("--allow-nonempty", action="store_true", help="писать в непустую БД приёмника")
    args = ap.parse_args()
    src_url, dst_url = os.environ.get("SRC_URL"), os.environ.get("DST_URL")
    if not src_url or not dst_url:
        print("✗ задайте SRC_URL и DST_URL (env)", file=sys.stderr)
        return 2
    try:
        src_info = connect(src_url, 0).info("server")
        dst_info = connect(dst_url, 0).info("server")
    except redis.exceptions.RedisError as e:
        print(f"✗ нет подключения к источнику/приёмнику: {e}", file=sys.stderr)
        return 2
    # Печатаем, КУДА пишем: run_id и версия однозначно отличают серверы (защита от port-forward не туда).
    for side, inf in (("src", src_info), ("dst", dst_info)):
        ver = inf.get("valkey_version") and f"valkey {inf['valkey_version']}" or f"redis {inf.get('redis_version')}"
        print(f"  {side}: {ver}, run_id {inf.get('run_id', '?')[:12]}")
    if src_info.get("run_id") == dst_info.get("run_id"):
        print("✗ источник и приёмник — один и тот же сервер", file=sys.stderr)
        return 2
    dbs = [int(x) for x in args.dbs.split(",")] if args.dbs else nonempty_dbs(connect(src_url, 0))
    print(f"→ БД: {dbs or '(пусто)'}")
    rc = 0
    if not args.verify_only:
        for db in dbs:
            rc |= copy_db(src_url, dst_url, db, args.dry_run, args.allow_nonempty)
    if not args.dry_run:
        for db in dbs:
            rc |= verify_db(src_url, dst_url, db)
    return rc


if __name__ == "__main__":
    sys.exit(main())
