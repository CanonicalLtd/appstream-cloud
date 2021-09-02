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

To update the configuration, edit config.json, *verify that it is valid json*
and then run

```shell
  juju set appstream-generator config="$(cat config.json)"
```

Sadly Juju doesn't have a native json type currently, so it has to be passed in
as a string and deserialised on the other side.

# Deploying the charms

You need to have access to the live environment, which means you need to be a
Canonical employee.

  * Build the charm using `charmcraft build` (`charmcraft` comes from a snap:
    `snap install charmcraft`).
  * Change to the `built-CHARMNAME` (`built-appstream-generator` or
    `built-appstream-frontend`) branch
    * use a `git worktree` for this so you can have both branches on your
      filesystem at once
  * Remove all non-hidden files: `rm -r *`
  * Unzip the output of the build step here; `unzip
    ../path/to/the/branch/charms/*/CHARMNAME/CHARMNAME.build`
  * Commit the changes: `git add .; git commit -m "New build"`
  * On the controller machine, execute `mojo run -m manifest-upgrade`

# License

Everything here is ⓒ Canonical and is licensed under the GPL-3. See `LICENSE`.
