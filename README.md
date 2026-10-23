# lemmy-private-mode

A script that switches a Lemmy instance to private mode during heavy load (e.g. a scraper attack) and back to public once it's calm again.

While private mode is on, anonymous visitors and scrapers are refused. Logged-in users and federation keep working.

## How to use

```bash
sudo install -m 755 lemmy-private-mode.sh /usr/local/bin/lemmy-private-mode
sudo lemmy-private-mode status
```

`status` should show your Postgres container and `private_instance: f`.

Add to root's crontab (`sudo crontab -e`):

```
* * * * * /usr/local/bin/lemmy-private-mode
```

Defaults: on at load 5, off once load stays at 3 or lower for 5 minutes. To change these, copy `lemmy-private-mode.conf.example` to `/etc/lemmy-private-mode.conf` and edit it.

Log: `/var/log/lemmy-private-mode.log`
