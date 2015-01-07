pihotenuse
==========

Pihotenuse is a **disk image development tool** for the
[Raspberry Pi](http://www.raspberrypi.org), specifically supporting the
[Raspbian](http://www.raspbian.org) distribution. It aims to take the pain out
of **creating, manipulating and flashing disk images** so you can get back to
actually using your pi.

Utilizing [Docker](https://www.docker.com) and [QEMU](http://www.qemu.org),
pihotenuse lets you run commands inside your disk image as if it was a real pi,
right from your OS X command line. Its **built-in apt repository** and **debian
package builder** make developing packages for Raspbian a snap. Copy-on-write
disk images are **fast** and **disposable** - ideal for trying out quick hacks
or incrementally building a large system.


Quickstart
----------

Pop in an SD card then:

```
$ bash <(curl https://piho.sh)      # Install pihotenuse
$ piho init                         # Initialize pihotenuse (once only)
$ piho create my-image              # Create an image named my-image
$ piho run my-image some --command  # Run *real commands* on your image!
$ piho clone my-image foo           # Duplicate the image
$ piho shell foo                    # Launch a *real shell* on your image!
$ piho deb bar http://foo/bar.dsc   # Build a debian package from source
$ piho run foo apt-get install bar  # ... then install it!
$ piho remove foo                   # Delete an image
$ piho flash my-image               # Flash an image to an SD card
```


Requirements
------------

* OS X
* [boot2docker](http://boot2docker.io)


Installation
------------

Run the following command in a terminal:

```
$ bash <(curl https://piho.sh)
```


Initialization
--------------

Pihotenuse requires a one-time initialization:

```
$ piho init
```

This command will download a base disk image (currently, the latest Raspbian)
and initialize the boot2docker virtual machine.

If you already have a local Raspbian-based image you'd like to use, the `init`
command accepts an image path as an argument:

```
$ piho init ~/picraft.img
```


Creating an image
-----------------

To create an image, give it a name:

```
$ piho create my-image
```

Creating an image clones the base image installed by `piho init`. To save space
and allow for rolling back changes, a copy-on-write image format is used. That
means creating images is cheap on disk.


Running a command in an image
-----------------------------

Simply prefix the command you want to run with `piho run <image name>`:

```
$ piho run my-image grep NAME /etc/os-release
PRETTY_NAME="Raspbian GNU/Linux 7 (wheezy)"
NAME="Raspbian GNU/Linux"
```

`STDIN` and `STDOUT` work as expected:

```
$ echo 1 | piho run my-image sed s/1/2/ | sed s/2/3/
3
```

There's also a `run` command alias `r` for convenience:

```
$ piho r my-image ls -al
```

If the command exits successfully, the changes to the disk image will be saved.
If it fails, the disk is automatically rolled back to its previous state:

```
$ piho r my-image bash -c 'echo one > /test'
$ piho r my-image cat /test
one
$ piho r my-image bash -c 'echo two > /test && exit 1'
WARNING: Command failed, rolling back changes
ERROR: Command failed
$ piho r my-image cat /test
one
```


Launching an image shell
------------------------

To launch an image shell, use the `shell` piho command:

```
$ piho shell my-image
Launching shell for my-image
root@356529f32bf5:/#
```

or using the `sh` command alias:

```
$ piho sh my-image
Launching shell for my-image
root@b572a1038427:/#
```

Just like the `run` command, successful exit of the shell will save any changes
to disk. If you use `ctrl-D` or `exit` to terminate the shell session, the exit
code of the **last run command** will be used to determine exit status for the
shell. If you want to *ensure* changes are saved, quit the shell with `exit 0`.


Copying files to an image
-------------------------

Sometimes you'd like to move *big* files into an image, and your clever use of
pipes to transfer files over STDOUT/STDIN just won't cut it. For that, there's
the `copy` command:

```
$ piho copy my-image /abs/path/to/src /another/optional/src /dest/on/image
```

Of course `copy` has a `cp` alias:

```
$ piho cp my-image /some/src /some/dest
```


Cloning an image
----------------

Images can be duplicated with the `clone` command:

```
$ piho clone my-image new-image
```

*Note:* Although the initial state of the cloned image will match the original,
it is technically a direct descendant of the piho base image. Therefore no
changes are ever synced between the original and cloned image.


Exporting an image
------------------

Once you're happy with the state of your image, you can export it as a raw image
file, ready to be flashed to an SD card:

```
$ piho export my-image ./my-image.img
```


Flashing an image
-----------------

Too lazy to export and *then* flash your image? That's why there's the 
`flash` command:

```
$ piho flash my-image
```

It tries to auto-detect your SD card, but you can also specify it manually (and
use the `f` alias):

```
$ piho f my-image /dev/disk4
```


Removing an image
-----------------

After you're done with an image, you can free its occupied disk space by
removing it:

```
$ piho remove my-image
```

or of course:

```
$ piho rm my-image
```


Building debian packages
------------------------

Pihotenuse comes with a built-in apt repository and support for building deb
packages from various sources. The apt repository is automatically added to the
apt sources list for all images, so any packages in the repo can be
`apt-get install`'d from within any image.

The easiest way to get packages into the repo is to give the `deb` command a
link to a binary deb package:

```
$ piho deb bc http://archive.raspbian.org/raspbian/pool/main/b/bc/bc_1.06.95-2_armhf.deb
```

*Note:* You must currently pass the package name as the first argument even if
it seems silly. *Especially* if it seems silly.

If you'd like to build from source, you can give `piho deb` a dsc file instead:

```
$ piho deb bc http://archive.raspbian.org/raspbian/pool/main/b/bc/bc_1.06.95-9.dsc
```

It's also possible to build a Python package from an sdist tarball:

```
$ piho pydeb python-serial https://pypi.python.org/packages/source/p/pyserial/pyserial-2.7.tar.gz
```

or build from source by passing in a git URL (with optional branch name):

```
$ piho pydeb python-octoprint https://github.com/xdissent/octoprint.git#setuptools
```

Packages are built within a special image called `debs` which is *always* rolled
back after each build to save space.

*Note:* Don't try to use the `deb` files from Debian's apt repositories - the
`arm` arch they target is different than the pi's.

**Protip:** Just find the package you want in
[wheezy-backports](https://packages.debian.org/wheezy-backports/) and give the
`dsc` link to piho!

Of course, not all packages are going to work on the pi out of the box. To patch
a package's source before building, provide a shell script as the third argument
to `piho deb`:

```
$ piho deb my-pkg http://some/url.dsc "sed -i s/broken/fixed/ /some/file"
```

If your patch script needs to access local files, just copy them to the `debs`
image beforehand.

Additionally, many packages accept a `DEB_BUILD_OPTIONS` environment variable to
configure the package. You can pass any build options as the fourth argument:

```
$ piho deb my-pkg http://some/url.dsc "sed -i s/broken/fixed/ /some/file" nocheck
```

To list the packages in your repository, try the `debs` command:

```
$ piho debs
haproxy
libsdl2
python-flask
```

The apt repository is **signed** using a pihotenuse-generated gpg key, which is
automatically trusted by all images. If the key is lost it will be regenerated
when required.

If the contents of the repository changes or the signing key is lost, the
repository must be reindexed:

```
$ piho index
```


Upgrading
---------

If you'd like to upgrade pihotenuse to the latest version, run:

```
$ piho upgrade
```

If you don't have permission to write to the current installation path, piho
will try to use sudo.


Updating
--------

Since pihotenuse is run inside Docker (and then inside QEMU), the Docker image
must be updated when the piho script itself is updated. Usually this won't be
required, but if you're making changes to piho and want to try them out, you
can run:

```
$ piho update
```

The container will be updated with the piho script thats **currently running**.

*Note:* This is done automatically when running `piho upgrade`.


Debugging
---------

There are two environment variable flags you may set to get more output
for debugging:

* **PIHO_DEBUG** - Enables debug log messages
* **PIHO_VERBOSE** - Enables bash execution tracing

These environment variables are passed through the execution stack all the way
down into the emulated pi environment.


Docker and Boot2docker
----------------------

Under the hood, pihotenuse uses boot2docker to drive Docker, which in turn
drives QEMU. You don't have to worry about any of that. But if you're a worrier,
you can get your hands on the underlying tools with the `boot2docker` and
`docker` commands:

```
$ piho boot2docker ssh
$ piho docker run -it some/image arbitrary --commands
```

Running QEMU directly is left as an exercise for the reader ;-)


FAQ
---

* **Why not just use QEMU?** - Tried it, and it's hard. Even if you can
  actually get it to install on OS X, you can't run `qemu-arm-static` for
  emulation - you can only emulate a full system. That's super slow. Plus you'd
  still have to remember a zillion obscure command incantations. No thanks.

* **Why not just use Docker then?** - A
  [couple](https://github.com/docker/docker/issues/1916) of
  [reasons](https://www.virtualbox.org/ticket/819).

* **Why no linux?** - Because Qemu and friends already play nicely with linux
  and it's pretty difficult to target all of the possible host environments. If
  you really wanted to, you could source piho into your own script and run its
  container functions directly - it won't run "main" if sourced.

* **Will this bork my boot2docker?** - Nope, it creates its own boot2docker
  profile and vm - your existing boot2docker stuff isn't ever touched.

* **Another copy+paste installer!?** - Hey, don't like it, don't paste it.

* **Why doesn't the installer work?** - Because you're not running the default
  shell. Try `/bin/bash -c '/bin/bash <(curl https://piho.sh)'`


TODO
----

* More docs
* Add per-command help
* Multiple bases / promote image to base
* Add compress command to shrink cow image if it grows larger than base
* Refactor chroot setup to support other distributions
* Create package repository backends for other distributions (arch/pacman first)
* Investigate Windows support


Fun Snippets
------------

Here are some random, useful snippets that are handy when building pi images.

***

Auto connect to a wifi network:

```
$ cat <<EOF | piho r x tee -a /etc/wpa_supplicant/wpa_supplicant.conf
network={
  ssid="Fort Awesome"
  psk="1234" # Same as my luggage
  key_mgmt=WPA-PSK
}
EOF
```

Prevent [the wifi adapter you know you have](http://www.amazon.com/Edimax-EW-7811Un-150Mbps-Raspberry-Supports/dp/B003MTTJOY)
from dropping out every 30 seconds:

```
$ echo "options 8192cu rtw_power_mgnt=0 rtw_enusbss=1 rtw_ips_mode=1" |
  piho r x tee /etc/modprobe.d/8192cu.conf
```

Add your public key to the pi user's authorized keys file:

```
$ cat ~/.ssh/id_rsa.pub | piho r x bash -c "exec 3<&0 &&
  mkdir -p ~pi/.ssh &&
  tee ~pi/.ssh/authorized_keys <&3 &&
  chown -R pi:pi ~pi/.ssh"
```

Turn off password authentication for sshd:

```
$ piho r x sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' \
  /etc/ssh/sshd_config
```

Change the hostname:

```
$ piho r x bash -c 'sed -i s/raspberrypi/$0/ /etc/hosts &&
  echo $0 > /etc/hostname' my-pi
```

Change the locale: (real time-saver if you've ever tried to do it on a pi!)

```
$ piho r x bash -c 'echo $0 $1 > /etc/locale.gen &&
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales' en_US.UTF-8 UTF-8
```

Change the timezone:

```
$ piho r x bash -c 'echo $0 > /etc/timezone &&
  dpkg-reconfigure -f noninteractive tzdata' America/Chicago
```

Set the keyboard layout:

```
$  cat <<EOF | piho r x tee /etc/default/keyboard
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
```

Prevent raspi-config from appearing on first boot:

```
$ piho r x bash -c 'rm -f /etc/profile.d/raspi-config.sh &&
  sed -i /etc/inittab -e /RPICFG_TO_DISABLE/d -e "/RPICFG_TO_ENABLE/ s/^#//"'
```

Free up a bunch of disk space:

```
$ piho r x bash -c "apt-get remove -y --purge \
    scratch \
    pypy-upstream \
    sonic-pi \
    freepats \
    libraspberrypi-doc \
    oracle-java8-jdk \
    wolfram-engine &&
  apt-get autoremove -y"
```

***

LICENSE: [TML](http://morrisseylicense.com)
