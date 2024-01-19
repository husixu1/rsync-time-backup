This post is copied from [rsync2u > rsync tutorial][1].

# The `exclude-from` and `recursive` options

Rsync can recursively traverse the source directory and copy every file in source to destination.  But there might be some junk (temp files, trash, and web-browser caches) that you rather not copy.

Excludes prevent rsync from backing up junk.  The rsync --exclude-from option is similar to the one in GNU tar.   Here is the option definition from the rsync man page:

```
--exclude-from=FILE     read exclude patterns from FILE
```

## The `exclude-from` file

The exclude file is a list of directory and file names to be excluded from the rsync destination e.g.

```
+ /source1/.fileA
- /source1/.*
- /source1/junk/
```

The format of the exclude file is one pattern per line.  The pattern can be a literal string, wildcard, or character range.

In UNIX, hidden files start with a dot (`.fileA` is a hidden file), and `*` is a wildcard (`.*` means all hidden files).

A leading `+` means include the pattern.  A leading `-` means exclude the pattern.

A path with a leading-slash must start with the source directory name (not the entire path).

Trailing slash is a directory (not a file).  No trailing slash can be a directory or a file.

Lines in an exclude file are read verbatim.  One frequent error is leaving some extra whitespace after a file name.

## The `exclude-from` and `recursive` options

This tutorial uses the `--recursive` (`-r`) option (which is implied by `-a`).  The default behavior of recursion is to traverse every branch of each source directory from the top down.  Here is an example usage:

```
rsync -ain --exclude-from=exclude source1 dest
```

The following is a description of how rsync excludes or includes names, where “name” is the name of a file or folder.

> For each name visited during the traversal of the source directory, rsync reads
> the list of patterns in the exclude file.  rsync reads the list top down, and the
> first matching pattern is acted on:
>
> - if it is a `-` pattern, then the name is excluded
> - if it is a `+` pattern, then the name is included
> - if no matching pattern is found, then the name is included
>
> If a directory name is excluded, that branch is skipped.
> If a directory name is included, the branch is traversed.

The order of the patterns matters, as the following examples illustrate.

## Setup `source1` directory for examples 2 & 3

The tutorial examples use a small directory.  Create the demo2 directory in your home directory:

```
user> mkdir demo2
```

Change to the rsync directory:

```
user> cd demo2
```

Create the source1 directory:

```
~/demo2$ mkdir source1 source1/junk source1/junk/keep
```

Now populate the source1 directory with files:

```
~/demo2$ touch \
    source1/.fileA source1/.fileB source1/file \
    source1/junk/file source1/junk/keep/fileX source1/junk/keep/fileY
```

Your source directory should look like this:

```
~/demo2$ ls source1 -AFR
source1:
file  .fileA  .fileB  junk/

source1/junk:
file  keep/

source1/junk/keep:
fileX  fileY
```

In the following examples, all commands are from the rsync directory.

## Example 2 `exclude-from` file

This example shows why the order of patterns matters.  Save the following text as rsync/exclude:

```
+ /source1/.fileA
- /source1/.*
- /source1/junk/
```

Assign permissions to the exclude file:

```
~/demo2$ chmod 755 exclude
```

Make sure that destination is removed:

```
~/demo2$ rm -r dest
```

Run rsync with the --exclude-from option:

```
~/demo2$ rsync -ain --exclude-from=exclude source1 dest
cd+++++++++ source1/
>f+++++++++ source1/.fileA
>f+++++++++ source1/file
```
rsync read the exclude list top down.  As expected, .fileA was backed up, and all other hidden files (.fileB) were skipped.

Now move the `-  /source1/.*` line to the top of the exclude file and save:

```
-  /source1/.*
+ /source1/.fileA
- /source1/junk/
```

Run rsync again:

    ~/demo2$ rsync -ain --exclude-from=exclude source1 dest
    cd+++++++++ source1/
    >f+++++++++ source1/file

This time `.fileA` did not get backed up.  Here is what happened:  rsync traversed the source1 directory.  When it visited `.fileA`, rsync read the exclude file top down, and acted on the first matching pattern.  The first matching pattern was `-  /source1/.*`, so `.fileA` was excluded.  Order of exclude files matters because rsync reads the exclude file top down.

## Example 3 `exclude-from` file

In this example we exclude an entire junk directory, except for one file.

Replace the contents of the exclude file with following lines and save:

```
+ /source1/junk/keep/
+ /source1/junk/keep/fileX
- /source1/junk/*
- /source1/junk/keep/*
```

The exclude file's strategy is to enter all the directories leading to fileX, and skip all the unwanted junk files and directories not leading to fileX.  To see how this works, trace the exclude file against the `rsync --recursive --exclude-from=FILE` algorithm near the top of this page.

Run rsync:

```bash
~/demo2$ rsync -ain --exclude-from=exclude source1 dest
cd+++++++++ source1/
>f+++++++++ source1/.fileA
>f+++++++++ source1/.fileB
>f+++++++++ source1/file
cd+++++++++ source1/junk/
cd+++++++++ source1/junk/keep/
>f+++++++++ source1/junk/keep/fileX
```

As planned, fileX is the only file in the junk directory that was backed up.

A common error is to forget specific include/exclude rules for all the parent directories that need to be visited.  For example, this exclude file will not backup fileX:

```
+ /source1/junk/keep/this/fileX
- /source1/junk/
```

```
~/demo2$ sync -ain --exclude-from=exclude source1 dest
cd+++++++++ source1/
>f+++++++++ source1/.fileA
>f+++++++++ source1/.fileB
>f+++++++++ source1/file
```

Here is what happened:  rsync traversed the source1 directory.  When it visited junk/, rsync read the exclude file top down, and acted on the first matching pattern.  The first matching pattern was `- /source1/junk/`, so entire junk directory was excluded.

## `exclude-file` suggestions

Consider the following items for your --exclude-from file:

```
#configuration files (Ubuntu 9.04)
+ /user/.config/
+ /user/.gnome2/

#desktop (Ubuntu 9.04)
- /user/Desktop/
- /user/examples.desktop

#firefox bookmarks, where "xxxxxxxx" represents a random string of 8 characters.
#http://support.mozilla.com/en-US/kb/Backing+up+your+information#Locate_your_profile_folder
+ /user/.mozilla/firefox/
+ /user/.mozilla/firefox/xxxxxxxx.default/
+ /user/.mozilla/firefox/xxxxxxxx.default/bookmarkbackups/
- /user/.mozilla/*
- /user/.mozilla/firefox/*
- /user/.mozilla/firefox/xxxxxxxx.default/*

#hidden files
- .*

#temporary files
- *.tmp
- *.temp
```

[1]:https://web.archive.org/web/20230126121643/https://sites.google.com/site/rsync2u/home/rsync-tutorial/the-exclude-from-option
