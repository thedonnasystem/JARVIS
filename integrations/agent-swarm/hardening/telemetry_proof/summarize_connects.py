import re, sys, json
strace, sink, label = sys.argv[1:4]
dests = {}
for line in open(strace, errors="replace"):
    m = re.search(r'connect\(\d+, \{sa_family=AF_INET6?, sin6?_port=htons\((\d+)\), (?:inet_pton\(AF_INET6, "([^"]+)"|sin_addr=inet_addr\("([^"]+)"\)|sin6_addr=inet_pton\(AF_INET6, "([^"]+)")', line)
    if not m: continue
    port = m.group(1); ip = m.group(2) or m.group(3) or m.group(4)
    res = "EINPROGRESS" if "EINPROGRESS" in line else ("OK" if "= 0" in line else line.strip().split("= ")[-1])
    dests[(ip, port)] = dests.get((ip, port), 0) + 1
ext = {k: v for k, v in dests.items() if not (k[0].startswith("127.") or k[0] in ("::1", "0.0.0.0", "::"))}
print(f"   [{label}] connect() destinations: {len(dests)}; non-loopback: {len(ext)} {sorted(ext)}")
kinds = {}
for l in open(sink):
    d = json.loads(l); kinds.setdefault(d["kind"], []).append(d["detail"][:140])
for k, v in kinds.items():
    print(f"   [{label}] sink {k}: {len(v)}"); [print("        ", x) for x in v[:6]]
if not kinds: print(f"   [{label}] sink: nothing received")
