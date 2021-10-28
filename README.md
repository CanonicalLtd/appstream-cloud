# Intro

This is the deployment for [appstream.ubuntu.com](https://appstream.ubuntu.com)
(or [staging](https://appstream.staging.ubuntu.com)).

# Structure

There are two main charms.

## appstream-generator

This installs the `appstream-generator` snap from the snap store, arranges for
it to be run on the configured Ubuntu releases, and then presents the results
over rsync for fetching by the Ubuntu archive and the frontend.

## appstream-frontend

This is a subordinate (to `apache2`) charm. It fetches from the generator's
rsync endpoint, and presents the data on the web for browsing.

## misc

The frontends are served over SSL. Termination is provided by haproxy. Frontends
can be scaled horizontally as needed. See the [mojo](https://mojo.canonical.com)
spec in `mojo/` for the deployment.

# Updating the config

When there's a new relase, you need to update the config. This does not require
rebuilding the charms.

To update the configuration, edit config.json, *verify that it is valid json*
and then run:

```
  $ pe appstream
  sudo -iu stg-appstream se stg-appstream   # (0) [WIP][PS5] stg-appstream
  sudo -iu prod-appstream se prod-appstream # (1) [WIP][PS5] prod-appstream
  Choose environment (q to quit): 1

  # Make config change on a local non-canonical system somewhere and commit
  # the config.json changes and pull them on the internal system.

  $juju config appstream-generator config="$(cat config.json)"
```

Sadly Juju doesn't have a native json type currently, so it has to be passed in
as a string and deserialised on the other side. After you update the config with
the `juju config` command, you're all done! After you add a new release, the
next complete run of the appstream-generator will generate the initial set of
appstream data for this release. Once that run is complete (logs available at
https://appstream.ubuntu.com/logs/), the output should be synced to
https://appstream.ubuntu.com within a couple of minutes, and to the Ubuntu archive
(http://archive.ubuntu.com/ubuntu/dists/<release>/<component>/dep11/) within a
couple of hours.

You can still do a sanity check before appstream.ubuntu.com updates by checking
the output of `juju config appstream-generator` and look for the config value
(key:value pair). The value should be the contents of `config.json`.

# Deploying the charms

You only need to rebuild the charms in charmcraft and deploy those changes if
you're making changes to the `appstream-cloud/charms` directory. The charm
changes should be made and built on a local non-canonical system. Then pull
`built-appstream-generator` branch changes on the internal canonical system.

To deploy the updated charms, you need to have access to the live environment
(the internal canonical system), which means you need to be a Canonical
employee.

  * After any charm changes, build the charm using `charmcraft build`
    (`charmcraft` comes from a snap: `snap install charmcraft`).
  * Change to the `built-CHARMNAME` (`built-appstream-generator` or
    `built-appstream-frontend`) branch
    * use a `git worktree` for this so you can have both branches on your
      filesystem at once
  * Remove all non-hidden files: `rm -r *`
  * Unzip the output of the build step here; `unzip
    ../path/to/the/branch/charms/*/CHARMNAME/CHARMNAME.build`
  * Commit the changes: `git add .; git commit -m "New build"`
  * Check `juju config appstream-generator` and look for the config value (key
    value pair). The value should be the contents of `config.json`.
  * On the controller machine, execute `mojo run -m manifest-upgrade`

# License

Everything here is ⓒ Canonical and is licensed under the GPL-3. See `LICENSE`.
