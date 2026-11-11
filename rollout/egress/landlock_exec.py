"""Run a command that can open TCP connections only to the given ports. Standard library only.

Usage: python3 landlock_exec.py --tcp-port 47121 [--tcp-port N ...] -- command args...

Applies a Landlock ruleset (Linux >= 6.7, ABI >= 4) that handles TCP connect and bind: connect is
allowed only to the listed ports (the egress proxy's), bind to none. On ABI >= 6 it also scopes
signals and abstract Unix sockets, so the command can't kill or talk to processes outside its
domain (the proxy, the sandbox server). Sets no_new_privs, restricts itself, then execs the
command; every child inherits the ruleset and nothing, root included, can lift it.

This needs no capability: HF Sandbox jobs have no CAP_NET_ADMIN, so iptables isn't an option, and
a root agent can undo /etc/hosts. Gaps: UDP isn't filtered (DNS still resolves), and Landlock
matches ports, not addresses (a remote host listening on an allowed port is reachable). Exits
non-zero without running the command if the kernel can't enforce the ruleset.
"""

from __future__ import annotations

import ctypes
import os
import struct
import sys

SYS_CREATE_RULESET, SYS_ADD_RULE, SYS_RESTRICT_SELF = 444, 445, 446  # x86_64 and arm64 alike
CREATE_RULESET_VERSION = 1
ACCESS_NET_BIND_TCP, ACCESS_NET_CONNECT_TCP = 1 << 0, 1 << 1
SCOPE_ABSTRACT_UNIX_SOCKET, SCOPE_SIGNAL = 1 << 0, 1 << 1
RULE_NET_PORT = 2
PR_SET_NO_NEW_PRIVS = 38


def main() -> int:
    args = sys.argv[1:]
    if "--" not in args:
        print(__doc__, file=sys.stderr)
        return 2
    split = args.index("--")
    options, command = args[:split], args[split + 1 :]
    ports = [int(options[i + 1]) for i, a in enumerate(options) if a == "--tcp-port"]
    if not command or not ports:
        print("need at least one --tcp-port and a command", file=sys.stderr)
        return 2

    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    abi = libc.syscall(SYS_CREATE_RULESET, None, ctypes.c_size_t(0), ctypes.c_uint32(CREATE_RULESET_VERSION))
    if abi < 4:
        print(f"landlock_exec: kernel Landlock ABI {abi} can't restrict TCP (needs 4)", file=sys.stderr)
        return 3

    scoped = SCOPE_ABSTRACT_UNIX_SOCKET | SCOPE_SIGNAL if abi >= 6 else 0
    if abi >= 6:
        attr = struct.pack("=QQQ", 0, ACCESS_NET_BIND_TCP | ACCESS_NET_CONNECT_TCP, scoped)
    else:
        attr = struct.pack("=QQ", 0, ACCESS_NET_BIND_TCP | ACCESS_NET_CONNECT_TCP)
    buf = ctypes.create_string_buffer(attr, len(attr))
    fd = libc.syscall(SYS_CREATE_RULESET, buf, ctypes.c_size_t(len(attr)), ctypes.c_uint32(0))
    if fd < 0:
        print(f"landlock_exec: create_ruleset failed (errno {ctypes.get_errno()})", file=sys.stderr)
        return 3
    for port in ports:
        rule = ctypes.create_string_buffer(struct.pack("=QQ", ACCESS_NET_CONNECT_TCP, port), 16)
        if libc.syscall(SYS_ADD_RULE, ctypes.c_int(fd), ctypes.c_int(RULE_NET_PORT), rule, ctypes.c_uint32(0)) != 0:
            print(f"landlock_exec: add_rule for port {port} failed (errno {ctypes.get_errno()})", file=sys.stderr)
            return 3
    if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        print("landlock_exec: no_new_privs failed", file=sys.stderr)
        return 3
    if libc.syscall(SYS_RESTRICT_SELF, ctypes.c_int(fd), ctypes.c_uint32(0)) != 0:
        print(f"landlock_exec: restrict_self failed (errno {ctypes.get_errno()})", file=sys.stderr)
        return 3
    os.close(fd)
    os.execvp(command[0], command)
    return 127


if __name__ == "__main__":
    sys.exit(main())
