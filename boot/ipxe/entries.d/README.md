# Extra iPXE menu entries

Every `*.sh` file here (and in `${PXE_IPXE_ENTRIES_DIR}`, if set in `config.local`) is sourced by
`boot/gen-boot-ipxe.sh` in name order. The menu is assembled as: group `diskless`, `debian`
(installers), `freebsd` (installer), `extra`, `other` (GRUB, shell, reboot); entries of a fragment
land in `extra` (after the FreeBSD installer, before "Other") unless it sets `cur_grp=diskless`
(and adds its gap with `((dl_gap)) || { add_gap "Diskless"; dl_gap=1; }`, as `freebsd-diskless.sh`
does). Keys 1-9 are handed out in final menu order; the first entry is the default. Files are plain bash that call:

    add_gap "Group title"                       # optional non-selectable heading
    add_item NAME "Menu label" [KEY] <<-EOF     # KEY: single character; default 1..9 numbering
        ...iPXE script lines (escape iPXE variables as \${platform}, \${srv}) ...
        goto failed
    EOF

Available in scope: `http_host`, `http_base` (= `PXE_HTTP_ROOT`), `PXE_*`/`DEBIAN_*` config
variables, and the iPXE variable `${srv}` (TFTP server) at boot time. Always end the body with
`goto failed` (returns to the menu after a message) and use `|| goto failed` on each command.

Regenerate and publish with `boot/deploy-menu.sh`.
Active fragments: `freebsd-diskless.sh` (FreeBSD 15.1 diskless, listed once the loaders exist in
`${PXE_IMAGES_ROOT}/tftp/freebsd/15.1_diskless/`; `PXE_FREEBSD_DISKLESS=0` hides it) and
`openbsd.sh` (OpenBSD installer, listed once published). A fragment adding to an existing group
checks `fb_gap` (FreeBSD) instead of calling `add_gap` again.
