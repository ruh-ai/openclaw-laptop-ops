# Operator SSH public keys

Drop one file per operator here, named after the Windows account it should log in as:
- `<WIN_USER>.pub` … or any name: keys whose basename is not a local Windows user are authorized for `WIN_USER`.
- Public keys only (`ssh-ed25519 AAAA...`). `.gitignore` blocks private keys, but don't test it.

`windows\11-openssh.ps1` installs them: admin accounts → `%ProgramData%\ssh\administrators_authorized_keys` (Windows rule),
non-admin accounts → `C:\Users\<user>\.ssh\authorized_keys`. Re-run the script after adding a key.

Generate on your machine: `ssh-keygen -t ed25519 -C "you@ruh.ai openclaw-laptop"` → copy `~/.ssh/id_ed25519.pub` here.
