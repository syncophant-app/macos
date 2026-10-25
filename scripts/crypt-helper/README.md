# rclone crypt helper

Build with Go 1.26 or newer:

```sh
go build -trimpath -o /absolute/path/to/syncophant-crypt .
```

`go.mod` and `go.sum` pin the official `github.com/rclone/rclone` module to
v1.75.2. rclone is MIT licensed; its notice is in `LICENSE-rclone`. Include
`THIRD_PARTY_NOTICES.txt` in distributed third-party notices; it contains the
top-level license/notice files for the compiled dependency modules and Go standard library.
Go produces a
native executable with no installed Go or rclone runtime requirement. Bundle and
sign it as `Resources/syncophant-crypt` in both the app and File Provider extension.
The application must use its bundled, signed helper, not a PATH lookup.

The helper accepts newline-delimited JSON on private stdin/stdout pipes. The first
message supplies the password and optional password2 (rclone's salt password).
Passwords and salts never appear in arguments, environment, logs or config files.
Subsequent operations use the derived cipher in memory. No network listeners or
rclone remote configurations are used. Diagnostic output is suppressed and errors
are generic so decrypted names and credentials cannot enter logs.
The Swift bridge uses nonblocking pipes, checks cancellation every 100 ms,
limits each response/write to 30 seconds, and suppresses SIGPIPE on its own pipe.

All cipher operations use rclone's exported `crypt.Cipher` methods. The format is
standard encrypted names, base32 encoding, directory name encryption enabled and
authenticated encrypted contents. `password2=""` uses rclone's default salt. Other
rclone filename modes/encodings are intentionally unsupported.

Uploads feed `Cipher.EncryptData` through a pipe into a private 0600 ciphertext
file in a 0700 temporary directory. Swift sends at most 16 MiB per command and
normally streams 1 MiB at a time. Resume re-encrypts the prior plaintext prefix
with a fresh nonce rather than reusing a nonce for a changed last block. Direct
writes preserve the old tail and rewrite ciphertext; callers uploading many
chunks should use `prepareUpload` / `finishUpload` once around the upload.
Memory stays bounded, but local ciphertext staging needs disk space proportional
to the file size; a transport's own ciphertext upload spool may coexist with it.
Ranged reads use `Cipher.DecryptDataSeek` and request only the encrypted header
and authenticated blocks covering the range. No plaintext temporary file exists.

Format limitations inherited from rclone: encrypted names are deterministic and
directory structure and content sizes remain observable. Per-block
authentication detects modified blocks but does not provide an external manifest
to detect all truncation or rollback attacks. A zero-byte file has only a header,
so it has no authenticated content block. Empty vaults cannot authenticate a key.
An undecodable name causes a vault/authentication error instead of an empty list.

Run `bash scripts/integration/crypt.sh` from the repository root for independent
installed-rclone interoperability and the focused Swift tests. Fixtures contain
public, explicitly documented test-only passwords, never real credentials.
