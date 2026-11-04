# BerthSMB

A pure-Swift SMB 2/3 client built for throughput and responsiveness. It powers Berth's cloud backend, and it is a standalone library with no dependencies beyond CryptoKit and CommonCrypto (swift-crypto on Linux).

```swift
let client = SMBClient(.init(host: "nas.local", share: "Media",
                             credentials: .user("jo", password: "…")))
let info = try await client.connect()                 // SMB 3.1.1 · AES-GMAC · 1024 KiB I/O
for item in try await client.contentsOfDirectory(at: "Photos") { print(item.name, item.size) }
try await client.download("Photos/beach.heic", to: localURL) { done, total in … }
try await client.upload(localURL, to: "Photos/beach-edit.heic")
for try await changes in client.changes(under: "Photos") { print(changes) }
```

## Why it's fast

- **Pipelining.** Requests don't wait for each other: any number of tasks share one connection and `await` their own responses. A transfer keeps `ioDepth` (16, or 32 on Tailscale/WAN) READs or WRITEs in flight, so a single file fills the link even when the round trip is long.
- **Large, multi-credit I/O.** 1 MiB per request by default (up to the server's 8 MiB MaxRead/WriteSize), charged as 64 KiB credits. The client asks for more credits with every request and keeps a window of 512–1024 open.
- **Compounding.** Metadata operations are one related compound, one round trip: `stat` is CREATE + QUERY_INFO + CLOSE, a rename is CREATE + SET_INFO + QUERY_INFO + CLOSE, and a directory listing of up to two buffers (thousands of entries) is CREATE + QUERY_DIRECTORY × 2 + CLOSE.
- **Few copies, few syscalls.** A dedicated reader thread parses, decrypts and verifies responses and resumes waiting tasks directly; downloads `pwrite` straight from the received frame. Requests are built in their final wire buffer (the 4-byte transport header is reserved up front), uploads `pread` straight into it, and a dedicated writer thread coalesces small frames into few `send` calls. TCP_NODELAY, 4–8 MiB socket buffers, keepalives.
- **Hardware crypto.** AES-GMAC signing (SMB 3.1.1's fastest), AES-128/256-GCM encryption and SHA-512 via CryptoKit; AES-CMAC on CommonCrypto's AES-CBC.
- **Atomic uploads in one extra round trip.** Data goes to a hidden temporary file; one compound then sets its timestamps, renames it over the destination and closes it.

Measured by CI (`berth-smb bench`, GitHub runner, loopback to Samba 4.19 with mandatory AES-GMAC signing on every message, 256 MiB file, 1 MiB × 16 in flight): **~1.7 GB/s upload, ~1.9 GB/s download** (verified byte-for-byte), **~3,150 metadata ops/s** (create + stat + delete, 32 in flight), 0.12 ms ECHO. Loopback measures client and server efficiency rather than a network; on real links the pipeline depth is what keeps throughput up as latency grows.

## Protocol coverage

| | |
| --- | --- |
| Dialects | 2.0.2, 2.1, 3.0, 3.0.2, 3.1.1 (negotiate contexts, pre-authentication integrity with SHA-512) |
| Authentication | NTLMv2 in SPNEGO, with the AUTHENTICATE MIC and the SPNEGO mechListMIC; guest; anonymous |
| Signing | HMAC-SHA256 (2.x), AES-CMAC (3.x), AES-GMAC (3.1.1). Responses are verified, including the final SESSION_SETUP (downgrade protection) |
| Encryption | AES-128-GCM and AES-256-GCM (3.1.1), per session or per share, or forced by the client |
| Operations | stat, list, read/download, write/upload, mkdir, delete (recursive), rename/move, set times/attributes, volume size and attributes, ECHO, CHANGE_NOTIFY |
| Symlinks | Reads NTFS and NFS symlink reparse points (FSCTL_GET_REPARSE_POINT) and XSym files (the format macOS smbfs and Linux `mfsymlinks` use). Creates reparse points where the volume supports them, XSym files otherwise. stat, delete and rename act on the link itself |
| Extended attributes | macOS xattr names over named streams, with the SFM character mapping and `AFP_AfpInfo`/`AFP_Resource` for FinderInfo and the resource fork (what smbfs and vfs_fruit use), or over SMB EAs (FileFullEaInformation) with escaped names on servers without streams. Setting them preserves the modification date |
| Resilience | Single-flight reconnect; idempotent operations retry once on a fresh connection; request deadlines (soft-mount semantics); async (STATUS_PENDING) responses and SMB2 CANCEL |

Not implemented: Kerberos, DFS, SMB 3.0 AES-CCM encryption, multichannel, leases/oplocks, compression, server-side copy.

## Layout

| Path | What |
| --- | --- |
| `Support/` | Little-endian encoding, FILETIME, NTSTATUS, errors |
| `Crypto/` | CryptoKit wrappers, SP800-108 KDF, MD4, RC4, AES-CMAC |
| `Auth/` | NTLMv2 and SPNEGO |
| `Protocol/` | Constants and every request/response the client uses |
| `Transport/` | The TCP socket |
| `Connection/` | The pipelined connection (credits, compounds, reader/writer threads), signing/sealing, handshake |
| `Client/` | `SMBClient`: reconnects, metadata operations, transfers, change notifications |

## Testing

```sh
swift test
```

runs the unit tests: RFC/MS-NLMP crypto and NTLMv2 vectors, plus byte-for-byte golden vectors for request encoding, signing and sealing, and parsing of responses captured from a real Samba 4.19 server.

Point it at a server for the integration suite (lifecycle, 24 MiB pipelined round trip, 200 concurrent operations on one connection, change notifications, reconnects, symlinks, extended attributes as EAs and as named streams, encrypted share):

```sh
BERTH_SMB_TEST_URL='smb://user:pass@127.0.0.1:4450/share' \
BERTH_SMB_TEST_ENCRYPTED_URL='smb://user:pass@127.0.0.1:4450/secure' \
BERTH_SMB_TEST_STREAMS_URL='smb://user:pass@127.0.0.1:4450/mac' swift test   # vfs objects = catia fruit streams_xattr
```

`berth-smb` is a small CLI on top of the library:

```sh
swift run -c release berth-smb info  smb://user@nas.local/Media      # what was negotiated
swift run -c release berth-smb bench smb://user@nas.local/Media --size 1024 --depth 32
SMB_PASSWORD=… swift run berth-smb ls smb://user@nas.local/Media/Photos
swift run berth-smb ln smb://user@nas.local/Media/Albums/Photos ../Photos   # symlink
swift run berth-smb xattr smb://user@nas.local/Media/Photos/beach.heic       # list xattrs
```
