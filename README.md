# Fedora Post-Installation Setup Script

This script automates the setup of a fresh Fedora Workstation (GNOME) installation with:
- Zsh with Oh My Zsh and Starship prompt
- Font collection (FiraCode Nerd Font, Noto, DejaVu, Liberation, Inter)
- RPM Fusion repositories (free, nonfree, and tainted)
- Essential system tools and applications
- Performance optimizations
- Third-party applications (Chrome, 1Password, Zed, etc.)

Only GNOME is supported.

## Usage

```bash
./fedora-setup.sh
```

Run it as your regular user (not root); it asks for the sudo password once.
If the initial system update requires a reboot, the script stops: reboot and run it again.
Logs are written to `~/.local/state/fedora-setup/`.

## Versions

- `main` — version 2: Zsh, Oh My Zsh and Starship, GNOME only.
- [`v1`](https://github.com/gtimchenko/fedora-setup/tree/v1) — version 1: Fish with Starship, GNOME and KDE.

## License

MIT. Author: Georgiy Timchenko.
