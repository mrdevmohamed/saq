PREFIX  ?= /usr
SBINDIR ?= $(PREFIX)/sbin
SHAREDIR ?= $(PREFIX)/share/saq
DESTDIR ?=

.PHONY: all check install uninstall

all:
	@echo "nothing to build; try 'make check' or 'make install DESTDIR=...'"

check:
	bash -n src/saq src/saq-live-iso
	sh -n share/saq/init
	sh -n share/saq/init-live
	shellcheck -s bash src/saq src/saq-live-iso tests/smoke.sh tests/live.sh
	shellcheck -s dash share/saq/init share/saq/init-live
	bash tests/smoke.sh
	bash tests/live.sh

install:
	install -Dm755 src/saq $(DESTDIR)$(SBINDIR)/saq
	install -Dm755 src/saq-live-iso $(DESTDIR)$(SBINDIR)/saq-live-iso
	install -Dm755 share/saq/init $(DESTDIR)$(SHAREDIR)/init
	install -Dm755 share/saq/init-live $(DESTDIR)$(SHAREDIR)/init-live
	install -Dm644 share/saq/modules-live.list $(DESTDIR)$(SHAREDIR)/modules-live.list
	install -Dm644 share/saq/modules.list $(DESTDIR)$(SHAREDIR)/modules.list

uninstall:
	rm -f $(DESTDIR)$(SBINDIR)/saq $(DESTDIR)$(SBINDIR)/saq-live-iso
	rm -rf $(DESTDIR)$(SHAREDIR)
