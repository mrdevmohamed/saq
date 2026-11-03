PREFIX  ?= /usr
SBINDIR ?= $(PREFIX)/sbin
SHAREDIR ?= $(PREFIX)/share/saq
DESTDIR ?=

.PHONY: all check install uninstall

all:
	@echo "nothing to build; try 'make check' or 'make install DESTDIR=...'"

check:
	bash -n src/saq
	busybox sh -n share/saq/init 2>/dev/null || sh -n share/saq/init
	shellcheck -s bash src/saq tests/smoke.sh
	shellcheck -s dash share/saq/init
	bash tests/smoke.sh

install:
	install -Dm755 src/saq $(DESTDIR)$(SBINDIR)/saq
	install -Dm755 share/saq/init $(DESTDIR)$(SHAREDIR)/init
	install -Dm644 share/saq/modules.list $(DESTDIR)$(SHAREDIR)/modules.list

uninstall:
	rm -f $(DESTDIR)$(SBINDIR)/saq
	rm -rf $(DESTDIR)$(SHAREDIR)
