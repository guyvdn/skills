"""Switch the box to key-only SSH with passwordless sudo, using a dedicated key.

    python keys_only.py <SERVER_IP> <USER> --bootstrap-key ~/.ssh/<OLD_KEY> [--key ~/.ssh/<NEW_KEY>]

Copy the sudo password to the clipboard first, then type or recall the command;
pasting the command overwrites the clipboard. The password stays in memory.

Each step verifies before the next can lock anything out, and a re-run skips
what is already done:
  1. create the dedicated key if missing
  2. install it with the bootstrap key and prove it logs in
  3. as root: NOPASSWD sudoers drop-in (visudo-checked before it is moved into
     place) and an sshd drop-in that turns password logins off
  4. in a fresh session, require `sudo -n`, then remove the bootstrap key
  5. confirm that the bootstrap key is refused and only publickey is offered
"""
import argparse, os, subprocess, sys
import paramiko


def connect(host, user, keyfile):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username=user, key_filename=keyfile, timeout=15,
              allow_agent=False, look_for_keys=False)
    return c


def run(c, cmd, stdin=None):
    i, o, e = c.exec_command(cmd)
    if stdin is not None:
        i.write(stdin)
    i.channel.shutdown_write()
    out = o.read().decode(errors="replace")
    err = e.read().decode(errors="replace")
    return o.channel.recv_exit_status(), out, err


def fail(msg):
    print(f"FAILED: {msg}")
    sys.exit(1)


ap = argparse.ArgumentParser()
ap.add_argument("host")
ap.add_argument("user")
ap.add_argument("--bootstrap-key", required=True, help="key that logs in today; removed at the end")
ap.add_argument("--key", help="dedicated key to create/use (default ~/.ssh/<host>_ed25519)")
a = ap.parse_args()
old = os.path.expanduser(a.bootstrap_key)
new = os.path.expanduser(a.key or f"~/.ssh/{a.host.replace('.', '_')}_ed25519")

print("\n== 1. Dedicated key")
if not os.path.exists(new):
    subprocess.run(["ssh-keygen", "-t", "ed25519", "-N", "", "-q",
                    "-C", f"devpc->{a.host}", "-f", new], check=True)
    print(f"created {new}")
else:
    print(f"exists  {new}")
new_pub = open(new + ".pub").read().strip()
new_blob = new_pub.split()[1]
old_blob = open(old + ".pub").read().split()[1]

print("\n== 2. Install and test the new key")
try:
    c = connect(a.host, a.user, new)
    print("new key already works")
except paramiko.AuthenticationException:
    c = connect(a.host, a.user, old)
    rc, _, err = run(c, f"grep -qF '{new_blob}' ~/.ssh/authorized_keys || "
                        f"echo '{new_pub}' >> ~/.ssh/authorized_keys")
    if rc:
        fail(err)
    c.close()
    c = connect(a.host, a.user, new)
    print("new key installed and logs in")

print("\n== 3. Passwordless sudo + key-only SSH")
rc, _, _ = run(c, "sudo -n true")
pw = ""
if rc:
    pw = subprocess.run(["powershell", "-NoProfile", "-Command", "Get-Clipboard -Raw"],
                        capture_output=True, text=True).stdout.rstrip("\r\n")
    if not pw:
        fail("clipboard is empty - copy the sudo password first")
# 00- so it wins over 50-cloud-init.conf, which may set PasswordAuthentication yes
script = rf'''set -e
echo '{a.user} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-{a.user}.tmp
chmod 440 /etc/sudoers.d/90-{a.user}.tmp
visudo -cf /etc/sudoers.d/90-{a.user}.tmp
mv /etc/sudoers.d/90-{a.user}.tmp /etc/sudoers.d/90-{a.user}
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/00-keys-only.conf
sshd -t
systemctl reload ssh
sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) '
'''
rc, out, err = run(c, "sudo -S -p '' bash -s", (pw + "\n" if pw else "") + script)
pw = None
print(out.strip())
if rc:
    fail(err.strip() or f"exit {rc}")
c.close()

print("\n== 4. Verify sudo, remove the bootstrap key")
c = connect(a.host, a.user, new)
rc, _, err = run(c, "sudo -n true")
if rc:
    fail("passwordless sudo does not work - bootstrap key left in place: " + err)
print("sudo -n OK")
rc, out, err = run(c, f"grep -vF '{old_blob}' ~/.ssh/authorized_keys > ~/.ssh/ak.new; "
                      "chmod 600 ~/.ssh/ak.new && mv ~/.ssh/ak.new ~/.ssh/authorized_keys && "
                      "awk '{print $1, $3}' ~/.ssh/authorized_keys")
if rc:
    fail(err)
print("authorized_keys now:\n" + out.strip())
c.close()

print("\n== 5. Confirm what is refused")
try:
    connect(a.host, a.user, old).close()
    print("WARNING: bootstrap key still logs in")
except paramiko.AuthenticationException:
    print("bootstrap key refused  OK")
t = paramiko.Transport((a.host, 22))
t.connect()
try:
    t.auth_none(a.user)
except paramiko.BadAuthenticationType as e:
    print("server offers:", e.allowed_types, " OK" if e.allowed_types == ["publickey"] else " CHECK")
t.close()
print(f"\nDone. Use:  ssh -i {new} {a.user}@{a.host} 'sudo ...'")
