# Copyright (c) 2026 Open-E, Inc.
#
# sos plugin for collecting diagnostics for the Open-E JovianDSS Proxmox plugin.

import glob
import os
import re

from sos.report.plugins import IndependentPlugin, Plugin, PluginOpt


class JovianDSS(Plugin, IndependentPlugin):
    """Collect Open-E JovianDSS Proxmox plugin diagnostics."""

    short_desc = "Open-E JovianDSS Proxmox plugin diagnostics"
    plugin_name = "joviandss"
    profiles = ("storage", "virt")
    option_list = [
        PluginOpt(
            "collect_pw_file_format",
            default=False,
            desc="collect sanitized JovianDSS password file format",
            long_desc=(
                "Read JovianDSS Proxmox sensitive password files and include "
                "sanitized copies in the report. Actual password values are "
                "replaced with '<secret password>'. This is useful when "
                "debugging malformed password files without exposing secrets."
            ),
            val_type=bool,
        ),
    ]

    def setup(self):
        self.add_forbidden_path([
            "/etc/pve/priv/storage/joviandss/*.pw",
            "/etc/pve/priv/storage/joviandss-nfs/*.pw",
        ])

        self.add_copy_spec([
            "/var/log/joviandss",
            "/etc/joviandss/state",
            "/etc/pve/priv/joviandss/state",
            "/etc/multipath/conf.d/open-e-joviandss.conf",
            "/etc/joviandss/multipath-open-e-joviandss.conf.example",
            "/etc/udev/rules.d/50-joviandss-scsi-skip-dm.rules",
            "/etc/lvm/lvm.conf",
        ])

        self.add_cmd_output([
            "dpkg -s open-e-joviandss-proxmox-plugin",
            "dpkg-query -W -f='${Version}\\n' open-e-joviandss-proxmox-plugin",
            "apt-cache policy open-e-joviandss-proxmox-plugin",
            "pvesm status",
            "pvesm config",
            "findmnt",
            "iscsiadm -m session",
            "iscsiadm -m node",
            "multipath -ll",
            "multipathd show maps",
            "multipathd show paths",
            "journalctl -u pvedaemon --since '2 hours ago' --no-pager",
            "journalctl -u pvestatd --since '2 hours ago' --no-pager",
            "journalctl -u iscsid --since '2 hours ago' --no-pager",
            "journalctl -u multipathd --since '2 hours ago' --no-pager",
        ], timeout=300)

        for storage_id in self._joviandss_storage_ids():
            self.add_cmd_output("pvesm list %s" % storage_id, timeout=300)

        for server in self._joviandss_nfs_servers():
            self.add_cmd_output([
                "showmount -e %s" % server,
                "rpcinfo -p %s" % server,
                "nc -vz %s 2049" % server,
            ], timeout=300)

        if self.get_option("collect_pw_file_format"):
            self._collect_sanitized_password_files()

    def _collect_sanitized_password_files(self):
        patterns = [
            "/etc/pve/priv/storage/joviandss/*.pw",
            "/etc/pve/priv/storage/joviandss-nfs/*.pw",
        ]

        for pattern in patterns:
            for path in sorted(glob.glob(pattern)):
                try:
                    with open(path, encoding="utf-8", errors="replace") as pwfile:
                        content = pwfile.read()
                except OSError as err:
                    self.add_string_as_file(
                        "failed to read %s: %s\n" % (path, err),
                        self._sanitized_pw_report_path(path) + ".error",
                    )
                    continue

                self.add_string_as_file(
                    self._sanitize_password_file_content(content),
                    self._sanitized_pw_report_path(path),
                    tags=["joviandss", "sanitized"],
                )

    def _sanitize_password_file_content(self, content):
        sanitized = []

        for line in content.splitlines(True):
            newline = ""
            body = line
            if body.endswith("\n"):
                newline = "\n"
                body = body[:-1]

            if not body.strip() or body.lstrip().startswith("#"):
                sanitized.append(body + newline)
                continue

            match = re.match(r"^(\s*user_password)(\s+)(.*?)(\s*)$", body)
            if match:
                sanitized.append(
                    "%s%s<secret password>%s%s" % (
                        match.group(1),
                        match.group(2),
                        match.group(4),
                        newline,
                    )
                )
                continue

            match = re.match(r"^(\s*\S+)(\s+)(.*?)(\s*)$", body)
            if match:
                sanitized.append(
                    "%s%s<secret password>%s%s" % (
                        match.group(1),
                        match.group(2),
                        match.group(4),
                        newline,
                    )
                )
                continue

            sanitized.append("<secret password>" + newline)

        return "".join(sanitized)

    def _sanitized_pw_report_path(self, path):
        relpath = path.lstrip(os.sep).replace(os.sep, ".")
        return "joviandss_sanitized_password_files/%s" % relpath

    def _storage_cfg_sections(self):
        cfg_path = "/etc/pve/storage.cfg"
        if not os.path.exists(cfg_path):
            return []

        sections = []
        current = None

        try:
            with open(cfg_path, encoding="utf-8", errors="replace") as cfg:
                for line in cfg:
                    line = line.rstrip("\n")
                    if not line.strip() or line.lstrip().startswith("#"):
                        continue

                    match = re.match(r"^(\S+):\s+(\S+)\s*$", line)
                    if match:
                        current = {
                            "type": match.group(1),
                            "id": match.group(2),
                            "options": {},
                        }
                        sections.append(current)
                        continue

                    if current is None:
                        continue

                    option = re.match(r"^\s+(\S+)(?:\s+(.*?))?\s*$", line)
                    if option:
                        current["options"][option.group(1)] = option.group(2) or ""
        except OSError:
            return []

        return sections

    def _joviandss_storage_ids(self):
        ids = []
        for section in self._storage_cfg_sections():
            if section["type"] in ("joviandss", "joviandss-nfs"):
                ids.append(section["id"])
        return sorted(set(ids))

    def _joviandss_nfs_servers(self):
        servers = []
        for section in self._storage_cfg_sections():
            if section["type"] != "joviandss-nfs":
                continue

            server = section["options"].get("server")
            if server and re.match(r"^[A-Za-z0-9_.:-]+$", server):
                servers.append(server)

        return sorted(set(servers))
