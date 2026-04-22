# IPFS RAM Mount

Mount an IPFS directory CID as a local folder using `rclone`, with the real mount and the default VFS cache stored in RAM.

The script exposes a visible folder on the Desktop by default so it is easy to open from graphical file managers, while the real FUSE mount lives under `${XDG_RUNTIME_DIR:-/dev/shm}`.

## Features

- Mounts an IPFS directory CID as a local read-only folder.
- Uses a local `rclone serve webdav` proxy in front of the HTTP gateway.
- Keeps the real mount in RAM.
- Keeps the default `rclone` VFS cache in RAM.
- Exposes a visible Desktop folder for GUI file managers.
- Resolves the Desktop path using XDG user directories when available, with a fallback to `$HOME/Desktop`.
- Cleans up the mount, symlink, temporary config, and RAM working directory on exit.

## How it works

The script creates this layout:

- Visible path: `Desktop/ipfs` by default.
- Real mount path: `${XDG_RUNTIME_DIR:-/dev/shm}/ipfs-mount/<CID>/mount`
- Default cache path: `${XDG_RUNTIME_DIR:-/dev/shm}/ipfs-mount/<CID>/cache`

The visible Desktop folder is a symbolic link to the RAM-backed real mount.

## Requirements

Install the required packages:

```bash
sudo apt install rclone fuse3 util-linux
```

Required tools:

- `rclone`
- `fusermount` or `fusermount3`
- `mountpoint`

## Quick start

Save the script, make it executable, and run it with a directory CID:

```bash
chmod +x mount-ipfs-RAM.sh
./mount-ipfs-RAM.sh bafybeigueuff67cztlt6dsv44s2pqwqfu4rxr5uvwynlbvjxug3ehe4siu
```

If everything works, the mounted content will appear in the visible Desktop folder, usually:

```bash
$HOME/Desktop/ipfs
```

## Usage

```text
./mount-ipfs-RAM.sh [OPTIONS] <CID>
```

### Arguments

- `CID` — IPFS directory CID to mount.

### Options

- `-m, --mount-point PATH` — override the visible mount path.
- `-c, --cache-dir PATH` — override the cache directory.
- `-s, --cache-size SIZE` — set the maximum VFS cache size, default `10G`.
- `-v, --verbose` — enable verbose `rclone` logging.
- `-h, --help` — show help.

## Examples

Mount to the default Desktop location:

```bash
./mount-ipfs-RAM.sh bafybeigueuff67cztlt6dsv44s2pqwqfu4rxr5uvwynlbvjxug3ehe4siu
```

Mount to a custom visible folder:

```bash
./mount-ipfs-RAM.sh -m "$HOME/ipfs" bafybeigueuff67cztlt6dsv44s2pqwqfu4rxr5uvwynlbvjxug3ehe4siu
```

Reduce RAM cache usage:

```bash
./mount-ipfs-RAM.sh -s 2G bafybeigueuff67cztlt6dsv44s2pqwqfu4rxr5uvwynlbvjxug3ehe4siu
```

Use a custom cache path:

```bash
./mount-ipfs-RAM.sh -c /tmp/ipfs-cache bafybeigueuff67cztlt6dsv44s2pqwqfu4rxr5uvwynlbvjxug3ehe4siu
```

## Notes

- The mount is read-only.
- The script is designed for directory CIDs.
- By default, both the real mount and the cache are RAM-backed.
- If `--cache-dir` points to a normal disk path, the cache will no longer be RAM-backed.
- `--poll-interval 0` is used to avoid unnecessary WebDAV polling messages.
- `--dir-cache-time 5m` means directory metadata may not refresh instantly.

## File manager behavior

The default visible path is placed on the Desktop so Nautilus, Dolphin, Thunar, and similar file managers can discover it more easily.

On systems using XDG user directories, the script reads `~/.config/user-dirs.dirs` and uses `XDG_DESKTOP_DIR` when present. Otherwise it falls back to `$HOME/Desktop`.

## Cleanup

Press `Ctrl+C` to unmount and remove:

- the FUSE mount
- the local visible symlink
- the temporary `rclone` config file
- the RAM-backed working directory

## Troubleshooting

### Mount succeeds but files do not refresh immediately

This is usually expected with WebDAV-backed mounts. The script uses a directory cache timer, so changes may appear after the cache expires.

### File manager does not show the folder on the Desktop

Check which Desktop path your session actually uses:

```bash
grep XDG_DESKTOP_DIR ~/.config/user-dirs.dirs 2>/dev/null || echo "$HOME/Desktop"
```

Then either move the visible mount path with `-m`, or update the XDG Desktop configuration.

### Cache is using too much RAM

Lower the cache size:

```bash
./mount-ipfs-RAM.sh -s 1G <CID>
```

### The visible path already exists

The script expects the visible path to be either absent, a removable symlink, or an empty directory. Remove or rename the existing path first.

## Security and behavior notes

- Content is fetched through the configured public IPFS gateway.
- The local WebDAV proxy listens on `localhost` only.
- The script generates a temporary `rclone` config file during execution and deletes it during cleanup.

## Suggested filename

Examples in this README use:

```text
mount-ipfs-RAM.sh
```

but the script can be renamed to any filename you prefer.
