# Independent rclone fixture

The adjacent `rclone-crypt-v1.72.1/` directory was created by the independently
installed `/usr/local/bin/rclone v1.72.1`, using `rclone --config /dev/null rcat`.
It is ciphertext, including its directory and file names.

Public test-only password: `syncophant-public-fixture-password`

Public test-only password2: `syncophant-public-fixture-salt`

The decrypted path is `Archive/independent.bin`. Its contents are 196735 bytes:
byte `index` equals `(index * 37 + 11) % 251`. The settings are standard/base32
filename encryption and directory name encryption enabled.

These public fixture strings are not credentials for any external storage.
