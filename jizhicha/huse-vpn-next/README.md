# HUSE VPN Next

Clean-room replacement client for the HUSE Gateway/SecWorld SSL VPN.

The old project is treated only as a protocol evidence archive. This project
contains no local account registration, no official-client FFI, no web-proxy
success shortcut, and no hard-coded credentials.

The credential path is the native SAC exchange used by `gwsession.dll`, not
the HTML login page. Each SAC request uses a fresh Gateway-compatible TLS
connection; the login response yields the NC ticket directly.

Connection stages:

1. Enumerate the gateway's authentication sources with SAC `0x02000002` and
   select `SAM-all`.
2. Authenticate the school account with SAC `0x02000003`.
3. Obtain the native 32-byte NC ticket.
4. Complete the captured Gateway-compatible TLS and NC authentication.
5. Create a Wintun interface and install only non-default campus routes.
6. Verify `ns.huse.cn` and `self.huse.cn` through the tunnel.
