# Extra iPXE menu entries

Every `*.sh` file here (and in `${PXE_IPXE_ENTRIES_DIR}`, if set in `config.local`) is sourced by
`boot/gen-boot-ipxe.sh` in name order, after the FreeBSD installer entries and before the
"Other" group (GRUB, shell, reboot). Files are plain bash that call:

    add_gap "Group title"                       # optional non-selectable heading
    add_item NAME "Menu label" [KEY] <<-EOF     # KEY: single character; default 1..9 numbering
        ...iPXE script lines (escape iPXE variables as \${platform}, \${srv}) ...
        goto failed
    EOF

Available in scope: `http_host`, `http_base` (= `PXE_HTTP_ROOT`), `PXE_*`/`DEBIAN_*` config
variables, and the iPXE variable `${srv}` (TFTP server) at boot time. Always end the body with
`goto failed` (returns to the menu after a message) and use `|| goto failed` on each command.

Regenerate and publish with `./boot/build-tftp-stage.sh` and the rsync in `boot/README.md`.
Active fragments: `freebsd-diskless.sh` (FreeBSD 15.1 diskless, listed once the loaders exist in
`${PXE_IMAGES_ROOT}/tftp/freebsd/15.1_diskless/`; `PXE_FREEBSD_DISKLESS=0` hides it) and
`openbsd.sh` (OpenBSD installer, listed once published). A fragment adding to an existing group
checks `fb_gap` (FreeBSD) instead of calling `add_gap` again.
