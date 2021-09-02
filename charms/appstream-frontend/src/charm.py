#!/usr/bin/env python3
# Copyright 2021 Canonical Ltd

# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <http://www.gnu.org/licenses/>.

import logging
import subprocess
from pathlib import Path
from textwrap import dedent

from ops.charm import CharmBase
from ops.framework import StoredState
from ops.main import main
from ops.model import ActiveStatus, BlockedStatus, MaintenanceStatus

logger = logging.getLogger(__name__)

PACKAGES_TO_INSTALL = ["rsync"]
RSYNC_ADDRESS_FILE = Path("~ubuntu/rsync-address").expanduser()
SYSTEMD_ENABLE_UNITS = ("sync-appstream.timer",)
SYSTEMD_UNITS = ("sync-appstream.service", "sync-appstream.timer")


class AppstreamFrontendCharm(CharmBase):
    """Charm the service."""

    _stored = StoredState()

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.install, self._on_install)
        self.framework.observe(
            self.on.rsync_relation_joined,
            self._on_appstream_rsync_relation_joined,
        )
        self.framework.observe(
            self.on.rsync_relation_departed,
            self._on_appstream_rsync_relation_departed,
        )
        self.framework.observe(
            self.on.apache_website_relation_joined,
            self._on_apache_website_relation_joined,
        )
        self.framework.observe(
            self.on.apache_website_relation_departed,
            self._on_apache_website_relation_departed,
        )
        self.framework.observe(self.on.upgrade_charm, self._on_upgrade_charm)
        self.framework.observe(self.on.start, self._on_start)
        self._stored.set_default(
            apache_related=False, installed_packages=set(), rsync_address=None
        )

    def _install_packages(self, packages):
        packages = packages - self._stored.installed_packages
        if not packages:
            logger.info("No packages to install.")
            return
        pkgs = ", ".join(packages)
        self.unit.status = MaintenanceStatus(f"Installing {pkgs}")
        logger.info(f"Installing apt package(s) {pkgs}")
        subprocess.check_call(
            [
                "apt-get",
                "--assume-yes",
                "--option=Dpkg::Options::=--force-confold",
                "install",
            ]
            + list(packages)
        )
        self._stored.installed_packages |= packages

    def _maybe_set_active(self):
        if self._stored.apache_related:
            self.unit.status = ActiveStatus()
        else:
            self.unit.status = BlockedStatus("Waiting for apache relation")

    def _symlink_scripts(self):
        home = Path("~ubuntu").expanduser()
        scripts_dir = Path(self.charm_dir) / "scripts"

        for script in scripts_dir.glob("*"):
            if script.is_dir():
                continue
            dest = home / script.name
            try:
                dest.symlink_to(script)
                logger.info(f"Symlinking {dest} → {script}")
            except FileExistsError:
                pass

    def _symlink_systemd_units(self):
        any_changed = False
        unit_dir = Path("/etc/systemd/system")
        charm_dir = Path(self.charm_dir)

        for unit in SYSTEMD_UNITS:
            dest = unit_dir / unit
            try:
                target = charm_dir / "units" / unit
                dest.symlink_to(target)
                any_changed = True
                logger.info(f"Symlinking {dest} → {target}")
            except FileExistsError:
                if dest.resolve() != target.resolve():
                    logger.info(
                        f"Target for {dest} has changed to {target}. Re-creating."
                    )
                    dest.unlink()
                    dest.symlink_to(target)
                    any_changed = True

    def _on_start(self, event):
        self._ensure_set_up(event)

        if not self._stored.rsync_address:
            logger.info("rsync address not set, can't start yet")
            self.unit.status = BlockedStatus(
                "Not related to appstream-generator, can't start yet."
            )
            event.defer()
            return

        for unit in SYSTEMD_ENABLE_UNITS:
            subprocess.check_call(
                ["systemctl", "enable", "--quiet", "--now", unit]
            )

        self._maybe_set_active()

    def _ensure_set_up(self, event):
        self._install_packages(PACKAGES_TO_INSTALL)
        self._symlink_scripts()
        self._symlink_systemd_units()

    def _on_install(self, event):
        self._ensure_set_up(event)

    def _on_appstream_rsync_relation_joined(self, event):
        data = event.relation.data[event.unit]
        private_address = data["private-address"]
        self._stored.rsync_address = private_address
        logger.info(f"rsync address is {private_address}")
        with open(RSYNC_ADDRESS_FILE, "w") as f:
            f.write(f"RSYNC_ADDRESS={private_address}\n")

    def _on_upgrade_charm(self, event):
        self._ensure_set_up(event)

    def _on_appstream_rsync_relation_departed(self, event):
        self._stored.rsync_address = None
        logger.info("rsync address removed, disabling")
        for unit in SYSTEMD_ENABLE_UNITS:
            subprocess.check_call(
                ["systemctl", "disable", "--quiet", "--now", unit]
            )
        RSYNC_ADDRESS_FILE.unlink()

    def _on_apache_website_relation_joined(self, event):
        if not self._stored.rsync_address:
            logger.info("rsync address not set, can't start yet")
            self.unit.status = BlockedStatus(
                "Not related to appstream-generator, can't set up website yet."
            )
            event.defer()
            return

        data = event.relation.data[self.unit]
        external_hostname = self.model.config.get("external-hostname")
        apache_config = dedent(
            f"""
            <Directory /home/ubuntu/appstream>
                Options Indexes FollowSymLinks
                Require all granted
            </Directory>

            <Directory /home/ubuntu/appstream/media>
                Options -Indexes
            </Directory>

            <Directory /home/ubuntu/logs>
                Options Indexes
                Require all granted
            </Directory>

            Alias /data /home/ubuntu/appstream/data
            Alias /media /home/ubuntu/appstream/media
            Alias /logs /home/ubuntu/logs
            Alias /hints /home/ubuntu/appstream/hints
            <VirtualHost *:80>
                ServerName {external_hostname}
                DocumentRoot /home/ubuntu/appstream/html
                ErrorLog ${{APACHE_LOG_DIR}}/error.log
                CustomLog ${{APACHE_LOG_DIR}}/custom.log combined
                AddType 'text/plain' .log
                AddCharset UTF-8 .log
            </VirtualHost>
            """
        )
        data["domain"] = external_hostname
        data["enabled"] = "true"
        data["ports"] = "80"
        data["site_config"] = apache_config
        data["site-modules"] = "autoindex"
        logger.info(f"Setting up apache site for {external_hostname}")
        self._stored.apache_related = True
        self._maybe_set_active()

    def _on_apache_website_relation_departed(self, event):
        self._stored.apache_related = False
        logger.info("apache relation removed, disabling")
        self._maybe_set_active()


if __name__ == "__main__":
    main(AppstreamFrontendCharm)
