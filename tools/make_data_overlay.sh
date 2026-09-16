#!/bin/sh
#
# make_data_overlay.sh - build a /data ext4 image that runs our payload at boot.
#
# /etc is an overlayfs whose upper layer is /data/system/etc/overlay, and /data
# is neither signed nor verity-protected. This stages:
#   - /system/etc/overlay/systemd/system/freemymprime.service  (runs setup.sh)
#   - /system/etc/overlay/systemd/system/multi-user.target.wants/freemymprime.service
#   - /ssh/setup.sh, /ssh/sshd_config, /ssh/authorized_keys
#
# setup.sh is deliberately dumb and observable: it sets a distinctive hostname,
# starts sshd, and starts a busybox telnetd fallback on 2323, logging to /data/ssh.
#
# Usage:
#   tools/make_data_overlay.sh --pubkey ~/.ssh/id_ed25519.pub --out work/data-ssh.img
#
set -eu

SIZE_MB=1024
LABEL=az01-data
PUBKEY=""
OUT=""
PASS=denon
SALT=freemymprime
FALLBACK_HASH='$6$freemymprime$oM4GYxDnIy5C0VLZI9PJ0nBbFyJJEUVc70GIjsFZk8.UjHoLxQcFuP.GCPAWWG3gBINiStSM1ongzf.lXh0Oh/'

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --pubkey) PUBKEY="$2"; shift 2 ;;
        --pubkey=*) PUBKEY="${1#*=}"; shift ;;
        --out) OUT="$2"; shift 2 ;;
        --out=*) OUT="${1#*=}"; shift ;;
        --size) SIZE_MB="$2"; shift 2 ;;
        --size=*) SIZE_MB="${1#*=}"; shift ;;
        --password) PASS="$2"; shift 2 ;;
        --password=*) PASS="${1#*=}"; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

[ -n "$OUT" ] || { echo "error: --out is required" >&2; usage 1; }
[ -n "$PUBKEY" ] || { echo "error: --pubkey is required" >&2; usage 1; }
[ -f "$PUBKEY" ] || { echo "error: public key not found: $PUBKEY" >&2; exit 1; }

HASH="$FALLBACK_HASH"
if command -v openssl >/dev/null 2>&1; then
    HASH="$(openssl passwd -6 -salt "$SALT" "$PASS")"
fi

STAGE="$(mktemp -d /tmp/az01-data.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
UPPER="$STAGE/system/etc/overlay"
WANTS="$UPPER/systemd/system/multi-user.target.wants"
mkdir -p "$WANTS" "$STAGE/system/var/overlay" "$STAGE/ssh"

# ---- /ssh/sshd_config ------------------------------------------------------
cat > "$STAGE/ssh/sshd_config" <<'EOF'
HostKey /data/ssh/ssh_host_ed25519_key
HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-ed25519
AuthorizedKeysFile /data/ssh/authorized_keys
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM no
Subsystem sftp /usr/libexec/sftp-server
EOF

# ---- /ssh/setup.sh ---------------------------------------------------------
cat > "$STAGE/ssh/setup.sh" <<EOF
#!/bin/sh
mkdir -p /var/run/sshd /data/ssh 2>/dev/null
exec >>/data/ssh/setup.log 2>&1
echo "=== FreeMyPrime setup \$(date) ==="
id
hostname freemymprime 2>/dev/null && echo "hostname set"

# host key
[ -f /data/ssh/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /data/ssh/ssh_host_ed25519_key

# root password (fallback for password auth)
HASH='$HASH'
if [ -s /etc/shadow ]; then
    awk -F: -v h="\$HASH" 'BEGIN{OFS=":"} \$1=="root"{\$2=h} {print}' /etc/shadow > /etc/shadow.tmp 2>/dev/null \
        && cat /etc/shadow.tmp > /etc/shadow && rm -f /etc/shadow.tmp
fi

# sshd
/usr/sbin/sshd -f /data/ssh/sshd_config 2>>/data/ssh/sshd.log
echo "sshd rc=\$?"

# observable fallback: busybox telnetd on 2323 (root shell)
if busybox --list 2>/dev/null | grep -qx telnetd; then
    busybox telnetd -p 2323 -l /bin/sh 2>>/data/ssh/telnetd.log
    echo "telnetd rc=\$?"
else
    echo "no busybox telnetd"
fi

# another fallback: busybox httpd
if busybox --list 2>/dev/null | grep -qx httpd; then
    busybox httpd -p 8080 -h /data 2>>/data/ssh/httpd.log
    echo "httpd rc=\$?"
fi
echo "=== done ==="
exit 0
EOF

cp "$PUBKEY" "$STAGE/ssh/authorized_keys"
cp "$(dirname "$0")/preload/freemymprime.so" "$STAGE/ssh/freemymprime.so"
# /etc/ld.so.preload (in the /etc overlay upper) -> glibc runs our constructor
# on Engine's next exec, without relying on systemd scanning the overlay.
printf '/data/ssh/freemymprime.so\n' > "$UPPER/ld.so.preload"
chmod 700 "$STAGE/ssh"; chmod 600 "$STAGE/ssh/authorized_keys" "$STAGE/ssh/sshd_config"; chmod 755 "$STAGE/ssh/setup.sh"; chmod 755 "$STAGE/ssh/freemymprime.so"; chmod 644 "$UPPER/ld.so.preload"

# ---- unit (in the /etc overlay upper) --------------------------------------
cat > "$UPPER/systemd/system/freemymprime.service" <<'EOF'
[Unit]
Description=FreeMyPrime boot payload
After=network.target

[Service]
Type=oneshot
ExecStart=/data/ssh/setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$UPPER/systemd/system/freemymprime.service"
ln -s /etc/systemd/system/freemymprime.service "$WANTS/freemymprime.service"

mkdir -p "$(dirname "$OUT")"; rm -f "$OUT"
echo "Creating ${OUT} (${SIZE_MB} MiB, ext4, label=${LABEL})"
mke2fs -q -t ext4 -O encrypt -L "$LABEL" -d "$STAGE" "$OUT" "${SIZE_MB}M"

CHOWN_CMDS="$(mktemp /tmp/az01-chown.XXXXXX)"
for p in \
    /ssh /ssh/sshd_config /ssh/authorized_keys /ssh/setup.sh /ssh/freemymprime.so \
    /system /system/etc /system/etc/overlay /system/etc/overlay/ld.so.preload \
    /system/etc/overlay/systemd /system/etc/overlay/systemd/system \
    /system/etc/overlay/systemd/system/freemymprime.service \
    /system/etc/overlay/systemd/system/multi-user.target.wants \
    /system/etc/overlay/systemd/system/multi-user.target.wants/freemymprime.service \
    /system/var /system/var/overlay
 do
    printf 'set_inode_field %s uid 0\nset_inode_field %s gid 0\n' "$p" "$p" >> "$CHOWN_CMDS"
done
debugfs -w -f "$CHOWN_CMDS" "$OUT" >/dev/null 2>&1
rm -f "$CHOWN_CMDS"

echo "Filesystem check:"
e2fsck -fy "$OUT" >/dev/null; echo "  e2fsck exit $?"
debugfs -R "ls -l /system/etc/overlay/systemd/system/multi-user.target.wants" "$OUT" 2>/dev/null
echo
echo "Flash:   fastboot flash data $OUT"
echo "Then boot normally and watch for:"
echo "  - port 22 (sshd) and 2323 (busybox telnetd fallback)"
echo "  - hostname 'freemymprime'"
echo "  - /data/ssh/setup.log on the device"
