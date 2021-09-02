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

import json
import logging
import os
import shutil
import subprocess
from pathlib import Path
from textwrap import dedent

from charmhelpers.core.hookenv import open_port
from ops.charm import CharmBase
from ops.framework import StoredState
from ops.main import main
from ops.model import ActiveStatus, BlockedStatus, MaintenanceStatus

logger = logging.getLogger(__name__)

# This is a special value that means we use the default channel, which comes
# from the charm config.
DEFAULT_SNAP_CHANNEL = None

APPSTREAM_BASE = Path("~ubuntu/appstream").expanduser()
APPSTREAM_PUBLIC = APPSTREAM_BASE / "appstream-public"
APPSTREAM_WORKDIR = APPSTREAM_BASE / "appstream-workdir"
ENVIRONMENT_FILE = Path("/etc/environment.d/proxy.conf")
INPUT_FILENAME = "asgen-config.json.in"
OUTPUT_FILENAME = APPSTREAM_WORKDIR / "asgen-config.json"
PACKAGES_TO_INSTALL = ["jq"]
SNAPS_TO_INSTALL = {"appstream-generator": DEFAULT_SNAP_CHANNEL}
SYSTEMD_ENABLE_UNITS = ("appstream-generator.timer",)
SYSTEMD_UNITS = ("appstream-generator.service", "appstream-generator.timer")

CONFIG_DEFAULT_PRIORITY = 0

CONFIG_PRIORITIES = {
    "updates": 10,
    "security": 20,
    "proposed": 30,
    "backports": 40,
}

CONFIG_HEADER = {
    "ProjectName": "Ubuntu",
    "Backend": "ubuntu",
    "Oldsuites": [],
    "Suites": {},
    "Features": {"validateMetainfo": True},
}


class AppstreamGeneratorCharm(CharmBase):
    _stored = StoredState()

    def __init__(self, *args):
        super().__init__(*args)

        self.framework.observe(self.on.config_changed, self._on_config_changed)
        self.framework.observe(self.on.install, self._on_install)
        self.framework.observe(
            self.on.appstream_storage_attached,
            self._on_appstream_storage_attached,
        )
        self.framework.observe(
            self.on.appstream_storage_detaching,
            self._on_appstream_storage_detaching,
        )
        self.framework.observe(self.on.start, self._on_start)
        self.framework.observe(self.on.clean_action, self._on_clean_action)
        self.framework.observe(self.on.forget_action, self._on_forget_action)
        self.framework.observe(
            self.on.forget_tag_action, self._on_forget_tag_action
        )

        self._stored.set_default(
            installed_packages=set(),
            installed_snaps=dict(),
            storage_attached=False,
        )

    def _on_clean_action(self, event):
        clean_file = APPSTREAM_BASE / "clean"
        with clean_file.open("w") as f:
            pass
        shutil.chown(clean_file, user="ubuntu", group="ubuntu")
        logger.info("Data will be cleaned with the next full run.")

    def _on_forget_action(self, event):
        forget_file = APPSTREAM_BASE / "forget"
        packages_raw = event.params["packages"]
        packages = json.loads(packages_raw)
        packages_s = ", ".join(packages)
        logger.info(f"Forgetting {packages_s}")
        with forget_file.open("a") as f:
            for package in packages:
                f.write(f"{package}\n")

    def _on_forget_tag_action(self, event):
        import lzma

        forget_file = APPSTREAM_BASE / "forget"
        hints_files = (APPSTREAM_PUBLIC / "hints").glob("*/*/Hints-*.xz")
        tag_to_forget = event.params["tag"]
        logger.info(f"Forgetting all packages with tag {tag_to_forget}")

        for filename in hints_files:
            p = set()
            hf = lzma.open(filename, "rt", encoding="utf-8")
            j = json.load(hf)
            for (v, pkg) in [
                (v, pkg)
                for (d, pkg) in [(t["hints"], t["package"]) for t in j]
                for v in d.values()
            ]:
                for i in v:
                    if i["tag"] == tag_to_forget:
                        p.add(pkg)

            with forget_file.open("a") as f:
                for pkg in p:
                    f.write(f"{pkg}\n")

    def _on_appstream_storage_attached(self, event):
        self._stored.storage_attached = True
        mp = self.meta.storages["appstream"].location
        shutil.chown(mp, user="ubuntu", group="ubuntu")
        try:
            APPSTREAM_WORKDIR.mkdir(parents=True, exist_ok=False)
            shutil.chown(APPSTREAM_WORKDIR, user="ubuntu", group="ubuntu")
        except FileExistsError:
            pass

    def _on_appstream_storage_detaching(self, _):
        self._stored.storage_attached = False

    def _on_start(self, event):
        if not self._ensure_set_up(event):
            return

        for unit in SYSTEMD_ENABLE_UNITS:
            subprocess.check_call(
                ["systemctl", "enable", "--quiet", "--now", unit]
            )
        self.unit.status = ActiveStatus()

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

    def _install_snaps(self, wanted_snaps):
        default_snap_channel = self.model.config.get(
            "default_snap_channel", "stable"
        )
        snaps_to_install = {}
        for snap in wanted_snaps:
            wanted_channel = wanted_snaps[snap] or default_snap_channel
            if snap not in self._stored.installed_snaps:
                verb = "install"
            else:
                if self._stored.installed_snaps[snap] == wanted_channel:
                    continue
                verb = "refresh"
            snaps_to_install[snap] = wanted_channel, verb

        if not snaps_to_install:
            logger.info("No snaps to install.")
            return
        snps_install = ", ".join(
            [s for s in snaps_to_install if snaps_to_install[s][1] == "install"]
        )
        status_list = []
        if snps_install:
            status_list.append(f"Installing snap packages: {snps_install}")
        snps_refresh = ", ".join(
            [
                f"{s}/{snaps_to_install[s][0]}"
                for s in snaps_to_install
                if snaps_to_install[s][1] == "refresh"
            ]
        )
        if snps_refresh:
            status_list.append(f"Refreshing snap packages: {snps_refresh}")
        status_string = "; ".join(status_list)

        self.unit.status = MaintenanceStatus(status_string)
        logger.info(status_string)
        for snap, (channel, verb) in snaps_to_install.items():
            subprocess.check_call(
                [
                    "snap",
                    verb,
                    "--channel",
                    channel,
                    snap,
                ],
            )
            self._stored.installed_snaps[snap] = channel

    def _set_up_proxy(self):
        http_proxy = self.model.config.get("http-proxy")
        https_proxy = self.model.config.get("https-proxy")
        no_proxy = self.model.config.get("no-proxy")

        if http_proxy or https_proxy or no_proxy:
            logger.info(f"Writing proxy settings to {ENVIRONMENT_FILE}")
            ENVIRONMENT_FILE.mkdir(parents=True, exist_ok=True)
            with ENVIRONMENT_FILE.open("w") as env:
                if http_proxy:
                    env.write(f"http_proxy={http_proxy}\n")
                if https_proxy:
                    env.write(f"https_proxy={https_proxy}\n")
                if no_proxy:
                    env.write(f"no_proxy={no_proxy}\n")
        else:
            try:
                os.unlink(ENVIRONMENT_FILE)
            except FileNotFoundError:
                pass

    def _config_process_suite(
        self, release, info, default_arches, default_suites
    ):
        out = {}
        for suite in (
            "%s%s" % (release, s) for s in info.get("suites", default_suites)
        ):
            out[suite] = {
                "useIconTheme": "Humanity",
                "dataPriority": CONFIG_PRIORITIES.get(
                    suite.split("-")[-1], CONFIG_DEFAULT_PRIORITY
                ),
                "sections": ["main", "universe", "multiverse", "restricted"],
                "architectures": info.get("architectures", default_arches),
            }
            if suite != release:
                out[suite]["baseSuite"] = release
        try:
            # if we have 'released' : true, make the base suite immutable
            info["released"]
            out[release]["immutable"] = True
        except KeyError:
            pass

        return out

    def _write_config(self):
        mirror = self.model.config.get("mirror")
        hostname = self.model.config.get("hostname")
        config = self.model.config.get("config")

        if not (mirror and hostname and config):
            logger.info("No config set. Can't continue.")
            return False

        config_j = json.loads(config)

        # Read the defaults
        default_arches = config_j["default"]["architectures"]
        default_suites = config_j["default"]["suites"]
        del config_j["default"]

        o = CONFIG_HEADER
        o["ArchiveRoot"] = mirror
        o["MediaBaseUrl"] = f"{hostname}/media"
        o["HtmlBaseUrl"] = hostname

        # Now do the rest
        for (release, ting) in config_j.items():
            if ting.get("oldSuite", False):
                CONFIG_HEADER["Oldsuites"].append(release)
            o["Suites"].update(
                self._config_process_suite(
                    release, ting, default_arches, default_suites
                )
            )

        OUTPUT_FILENAME.parent.mkdir(parents=True, exist_ok=True)
        with OUTPUT_FILENAME.open("w") as f:
            f.write(json.dumps(o, indent=4, sort_keys=True))
        shutil.chown(OUTPUT_FILENAME, user="ubuntu", group="ubuntu")

        return True

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

        if any_changed:
            subprocess.check_call(["systemctl", "daemon-reload"])

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

    def _set_up_rsync(self):
        any_written = False
        rsync_conf = Path("/etc/rsyncd.conf")
        rsync_d = Path("/etc/rsync-juju.d/")
        names_paths = (
            ("appstream", APPSTREAM_PUBLIC / "data"),
            ("www", APPSTREAM_PUBLIC),
            ("logs", APPSTREAM_BASE / "logs"),
        )
        rsync_template = dedent(
            """[{name}]
            path = {path}
            read only = yes
            list = yes
            uid = ubuntu
            gid = ubuntu
            chroot = false
        """
        )

        try:
            # XXX: This means if we change the template, changes will not be
            # written to the output file.
            with rsync_conf.open("x") as f:
                f.write(
                    dedent(
                        """
                    uid = nobody
                    gid = nogroup
                    pid file = /var/run/rsyncd.pid
                    syslog facility = daemon
                    socket options = SO_KEEPALIVE
                    timeout = 7200

                    &include /etc/rsync-juju.d
                """
                    )
                )
        except FileExistsError:
            pass

        rsync_d.mkdir(parents=True, exist_ok=True)

        for name, path in names_paths:
            path.mkdir(parents=True, exist_ok=True)
            try:
                # XXX: This means if we change the template above, changes will
                # not be written to the output file.
                conf = rsync_d / f"{name}.conf"
                with conf.open("x") as f:
                    logger.info(f"Writing rsync config to {conf}")
                    f.write(rsync_template.format(name=name, path=path))
                    any_written = True
            except FileExistsError:
                pass

        if any_written:
            subprocess.check_call(["systemctl", "restart", "rsync"])
            open_port(873)

    def _ensure_set_up(self, event):
        if not self._stored.storage_attached:
            event.defer()
            self.unit.status = BlockedStatus(
                "Waiting for storage to become attached."
            )
            return False

        self._install_packages(set(PACKAGES_TO_INSTALL))
        self._install_snaps(SNAPS_TO_INSTALL)
        self._set_up_proxy()
        self._symlink_systemd_units()
        self._symlink_scripts()
        self._set_up_rsync()

        if not self._write_config():
            logger.info("Failed to write config. Blocked.")
            event.defer()
            self.unit.status = BlockedStatus(
                "Config not set. Make sure config, hostname and mirror are set."
            )
            return False

        return True

    def _on_install(self, event):
        self._ensure_set_up(event)

    def _on_config_changed(self, event):
        if "appstream-generator" not in self._stored.installed_snaps:
            event.defer()
            return

        self._ensure_set_up(event)


if __name__ == "__main__":
    main(AppstreamGeneratorCharm)
