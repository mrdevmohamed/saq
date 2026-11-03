PREFIX  ?= /usr
SBINDIR ?= $(PREFIX)/sbin
SHAREDIR ?= $(PREFIX)/share/faseela-initramfs
DESTDIR ?=

.PHONY: all check install uninstall

all:
	@echo "nothing to build; try 'make check' or 'make install DESTDIR=...'"

check:
	bash -n src/faseela-mkinitramfs
	busybox sh -n share/faseela-initramfs/init 2>/dev/null || sh -n share/faseela-initramfs/init
	shellcheck -s bash src/faseela-mkinitramfs tests/smoke.sh
	shellcheck -s dash share/faseela-initramfs/init
	bash tests/smoke.sh

install:
	install -Dm755 src/faseela-mkinitramfs $(DESTDIR)$(SBINDIR)/faseela-mkinitramfs
	install -Dm755 share/faseela-initramfs/init $(DESTDIR)$(SHAREDIR)/init
	install -Dm644 share/faseela-initramfs/modules.list $(DESTDIR)$(SHAREDIR)/modules.list

uninstall:
	rm -f $(DESTDIR)$(SBINDIR)/faseela-mkinitramfs
	rm -rf $(DESTDIR)$(SHAREDIR)
