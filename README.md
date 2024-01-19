[[toc]]

# Rsync time backup

This tool is completely rewritten. The original script can be found on [laurent22/rsync-time-backup][0].

> This script offers Time Machine-style backup using rsync. It creates incremental backups of files and directories to the destination of your choice. The backups are structured in a way that makes it easy to recover any file at any point in time.
>
> It works on Linux, macOS, and Windows (via WSL or Cygwin). The main advantage over Time Machine is the flexibility as it can backup from/to any filesystem and works on any platform. You can also backup, for example, to a Truecrypt drive without any problem.
>
> On macOS, it has a few disadvantages compared to Time Machine - in particular, it does not auto-start when the backup drive is plugged (though it can be achieved using a launch agent), it requires some knowledge of the command line, and no specific GUI is provided to restore files. Instead, files can be restored by using any file explorer, including Finder, or the command line.

## Installation

```bash
git clone https://github.com/husixu1/rsync-time-backup
```

## Usage

```
USAGE
    rsync-tmbackup.sh [OPTION]... [--] \
        [[USER@]HOST:]<SOURCE> [[USER@]HOST:]<DESTINATION> [exclude-pattern-file]

OPTIONS
    -p <PORT>, --port <PORT>
        SSH port.

    -h, --help, -?
        Display this help message.

    -i <RSA_KEY>, --id-rsa <RSA_KEY>
        Specify the private ssh key to use.

    -rgf, --rsync-get-flags
        Display the default rsync flags that are used for backup. If using
        remote drive over SSH, --compress will be added.

    -rsf, --rsync-set-flags
        Set the rsync flags that are going to be used for backup.

    -raf, --rsync-append-flags
        Append the rsync flags that are going to be used for backup.

    -ld, --log-dir <DIR> (Default: $HOME/.cache/rsync-tmbackup)
        Set the log file directory. If this flag is set, generated files
        will not be managed by the script - in particular they will not be
        automatically deleted.

    -r, --retention "<M1:N1> <M2:N2> ..." (Default: 1:7 7:8 30:12 365:999999)
        Retention policy (overrides --strategy). Keeps the most recent Ni
        copies of per-Mi-days backup. The default means that keep 7 copies of
        most recent daily backup, keep 8 copies of most recent weekly backup,
        keep 12 copies of recent monthly backup and keep infinite yearly
        backups. Infinite sub-day backups are also kept, but they are subject
        to removal by the retention policy after one day of their creation.
        Mi and Ni must be positive integers. The option value must be quoted.

    -s, --strategy "<X1:Y1> <X2:Y2> ..." (Default: 1:1 30:7 365:30)
        Use old retention policy. Keeps backup every Yi days before Xi
        days ago. The default means before one day ago, keep one backup per
        day. Before 30 days ago, keep one backup every 7 days. Before 365 days
        ago, keep one backup every 30 days. This option is kept to maintain
        compatibility with the original script. The option value must be
        quoted. See https://github.com/laurent22/rsync-time-backup

    -nae, --no-auto-expire
        Disable automatically deleting backups when out of space. Instead an
        error is logged, and the backup is aborted.
```

# What's new

- Naming
    - Renamed `rsync_tmbackup.sh` to `rsync-tmbackup.sh`.

## New features

- Wrapper [scheduling script](rsync-tmsched.sh) to configure multiple backups plans in one place.
- New intuitive [retention policy](#retention-policy).
- Less external dependencies
    - `coreutils`, and `rsync` are still needed.
    - `ssh` is needed for executing commands remotely.
    - Completely eliminated dependency on `find`, `grep`, `sed` (non-coreutils).
- Less limitations
    - Allow arbitrary source/destination folder names.
    - Allow abbreviated ssh source/destination (`server:path` instead of `user@server:path`).
    - Allow arbitrary ssh login shell such as `fish`, which will always execute commands in bash.
    - Will verify directory name before purging (must be a valid date-time).
- Modern and robust bash:
    - Namespaced all functions and eliminated all global variables. Now it can be sourced as a bash library without possible naming conflict or variable pollution.
    - Eliminated most unsafe `eval`s. Only one safe `eval` remains in `rbkp.__run()`.
- Tests with [bash_unit][1] (see [tests](tests/)).
    - Writing tests can be tedious, but it helps incremental development.
    - Coverage support through [bashcov][2] (although not very precise), and CI with GitHub Actions.

## New limitations

- Requires `bash>=5.0` (to support features like `@Q`, `@a`, ...).

# Details

## Features summary

The following features are kept backward-compatible.

> * Each backup is in its own folder named after the current timestamp.
    Files can be copied and restored directly, without any intermediate tool.
> * Backup to/from remote destinations over SSH.
> * Files that haven't changed from one backup to the next are hard-linked to
    the previous backup so take very little extra space.
> * Safety check - the backup will only happen if the destination has explicitly
    been marked as a backup destination.
> * Resume feature - if a backup has failed or was interrupted, the tool will
    resume from there on the next backup.
> * Exclude file - support for pattern-based exclusion via the `--exclude-from`
    rsync parameter.
> * "latest" symlink that points to the latest successful backup.

The following feature is overridden by a new one (see [retention policy](#retention-policy)).
> * Automatically purge old backups - within 24 hours, all backups are kept.
    Within one month, the most recent backup for each day is kept.
    For all previous backups, the most recent of each month is kept.

## Examples

- Backup the home folder to backup_drive
    ```bash
    rsync-tmbackup.sh /home /mnt/backup_drive
    ```
- Backup with exclusion list:
    ```bash
    rsync-tmbackup.sh /home /mnt/backup_drive excluded_patterns.txt
    ```
- Backup to remote drive over SSH, on port 2222:
    ```bash
    rsync-tmbackup.sh -p 2222 /home user@example.com:/mnt/backup_drive
    ```
- Backup from remote drive over SSH:
    ```bash
    rsync-tmbackup.sh user@example.com:/home /mnt/backup_drive
    ```
- It is recommended to use systemd-timer with the [rsync-tmsched.sh](rsync-tmsched.sh).
    - `/etc/systemd/system/rsync-backup.service`
        ```ini
        [Unit]
        Description=One-shot rsync backup

        [Service]
        Type=oneshot
        User=root
        ExecStart=/<path-to-rsync-tmsched.sh>
        ```
    - `/etc/systemd/system/rsync-backup.timer`
        ```ini
        [Unit]
        Description=Runs rsync backup every night

        [Timer]
        OnCalendar=*-*-* 01:00:00
        Persistent=true

        [Install]
        WantedBy=timers.target
        ```

The following example is not tested, but it should work.

> - To mimic Time Machine's behaviour, a cron script can be setup to backup at regular interval. For example, the following cron job checks if the drive "/mnt/backup" is currently connected and, if it is, starts the backup. It does this check every 1 hour.
>     ```bash
>     0 */1 * * * if grep -qs /mnt/backup /proc/mounts; then rsync-tmbackup.sh /home /mnt/backup; fi
>     ```

## Retention policy

### New retention policy

Backups are automatically deleted following a retention policy defined by `--retention`. This strategy is a series of `M:N` pairs, which means "keep the most recent `N` copies of per-`M`-day backup.". The default strategy is `1:7 7:8 30:12 365:999999`, which means:

- Keep 7 daily backups.
- Keep 8 weekly backups.
- Keep 12 monthly backups (imprecise. month can have 28~31 days).
- Keep infinite yearly backups.

Using the default policy, around 28 backups will be kept in a 3-year span. See [test-retention-policy.sh](tests/test-retention-policy.sh) for deatils.

### Backup expiration logic

The following is the old retention policy. This function is kept for backward compatibility. Using the default `--strategy`, around 96 backups will be kept in a 3-year span. See [test-retention-policy.sh](tests/test-retention-policy.sh) for deatils.

> Backup sets are automatically deleted following a simple expiration strategy defined with the `--strategy` flag. This strategy is a series of time intervals with each item being defined as `x:y`, which means "after x days, keep one backup every y days". The default strategy is `1:1 30:7 365:30`, which means:
>
> - After **1** day, keep one backup every **1** day (**1:1**).
> - After **30** days, keep one backup every **7** days (**30:7**).
> - After **365** days, keep one backup every **30** days (**365:30**).
>
> Before the first interval (i.e. by default within the first 24h) it is implied that all backup sets are kept. Additionally, if the backup destination directory is full, the oldest backups are deleted until enough space is available.

## Other features

All features are kept.

> ### Exclusion file
>
> An optional exclude file can be provided as a third parameter. It should be compatible with the `--exclude-from` parameter of rsync. See [this tutorial](docs/rsync_options.md) for more information.
>
> ### Built-in lock
>
> The script is designed so that only one backup operation can be active for a given directory. If a new backup operation is started while another is still active (i.e. it has not finished yet), the new one will be automatically interrupted. Thanks to this the use of `flock` to run the script is not necessary.
>
> ### Rsync options
>
> To display the rsync options that are used for backup, run `./rsync-tmbackup.sh --rsync-get-flags`. It is also possible to add or remove options using the `--rsync-append-flags` or `--rsync-set-flags` option. For example, to exclude backing up permissions and groups:
>
> ```bash
> rsync_tmbackup --rsync-append-flags "--no-perms --no-group" /src /dest
> ```
>
> ### No automatic backup expiration
>
> An option to disable the default behaviour to purge old backups when out of space. This option is set with the `--no-auto-expire` flag.

## How to restore

Quote:

> The script creates a backup in a regular directory so you can simply copy the files back to the original directory. You could do that with something like `rsync -aP /path/to/last/backup/ /path/to/restore/to/`. Consider using the `--dry-run` option to check what exactly is going to be copied. Use `--delete` if you also want to delete files that exist in the destination but not in the backup (obviously extra care must be taken when using this option).

# Misc

These are the extensions built on top of [laurent22/rsync-time-backup][0].
They are not tested on the new `rsync-tmbackup.sh`.

> ## Extensions
>
> - [rtb-wrapper](https://github.com/thomas-mc-work/rtb-wrapper): Allows creating backup profiles in config files. Handles both backup and restore operations.
> - [time-travel](https://github.com/joekerna/time-travel): Smooth integration into OSX Notification Center

## LICENSE

MIT. See [LICENSE](LICENSE).

[0]:https://github.com/laurent22/rsync-time-backup
[1]:https://github.com/pgrange/bash_unit
[2]:https://github.com/infertux/bashcov

