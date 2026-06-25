# Makefile — install/uninstall for rodin-headless.
#
# GNU make recommended; written without GNU-only constructs so BSD make
# (the stock macOS /usr/bin/make) also works. Packagers drive it the usual
# way, which is what debhelper, RPM %make_install, Gentoo's emake, and a
# Homebrew formula's `system "make", "install"` all do under the hood:
#
#   make install   DESTDIR=/path/to/stage prefix=/usr
#   make uninstall DESTDIR=/path/to/stage prefix=/usr
#
# Standard GNU directory variables; override any on the command line.

prefix      ?= /usr/local
exec_prefix ?= $(prefix)
bindir      ?= $(exec_prefix)/bin
libexecdir  ?= $(exec_prefix)/libexec
datarootdir ?= $(prefix)/share
datadir     ?= $(datarootdir)
mandir      ?= $(datarootdir)/man
man1dir     ?= $(mandir)/man1

INSTALL      ?= install
INSTALL_DATA ?= $(INSTALL) -m 644

# Per-package subdirectories: internal scripts + library under libexec,
# the docker build context + VERSION under datadir. The $PATH entry points
# locate these at runtime via the sentinels rewritten at install time.
pkglibexecdir = $(libexecdir)/rodin-headless
pkgdatadir    = $(datadir)/rodin-headless

# User-facing commands installed on $PATH.
BIN_WRAPPER   = rodin-headless
BIN_INSTALLER = rodin-headless-install

# Internal executables carrying the libexec sentinel (sourced/exec'd by the
# entry points). entrypoint.sh has no sentinel but finds its sibling engine
# by directory; running it through the substitution is a harmless no-op.
LIBEXEC_SCRIPTS = rodin-headless.sh rodin-version.sh prob-version.sh entrypoint.sh

# The sourced library has no shebang and no sentinel — installed as data.
LIBEXEC_LIB = rodin-headless-lib.sh

# Verbatim payload for $pkgdatadir: the docker build context the wrapper
# uses for a local image build, plus VERSION. NOT sentinel-substituted —
# the in-image copies resolve their siblings by directory (dirname "$$0").
DATA_FILES = Dockerfile $(BIN_INSTALLER) rodin-version.sh prob-version.sh \
             rodin-headless.sh $(LIBEXEC_LIB) entrypoint.sh VERSION

.PHONY: all install uninstall

all:
	@echo "Nothing to compile. Targets: install, uninstall (override prefix/DESTDIR)."

# Run as a single shell invocation so the escaped paths and the subst()
# helper are shared across every step, and `set -e` aborts on the first
# failure. esc() backslash-escapes the sed metacharacters (\ & |) that the
# install path or VERSION could contain, so a prefix/DESTDIR with an '&' or
# '|' rewrites the sentinels correctly instead of corrupting them.
install:
	@set -e; \
	esc() { printf '%s' "$$1" | sed 's/[\\&|]/\\&/g'; }; \
	libexec_esc=$$(esc "$(pkglibexecdir)"); \
	datadir_esc=$$(esc "$(pkgdatadir)"); \
	subst() { sed -e "s|__RODIN_HEADLESS_LIBEXEC__|$$libexec_esc|g" \
	              -e "s|__RODIN_HEADLESS_DATADIR__|$$datadir_esc|g" "$$1"; }; \
	ver=$$(head -1 VERSION 2>/dev/null || echo unknown); \
	[ -n "$$ver" ] || ver=unknown; \
	ver_esc=$$(esc "$$ver"); \
	echo "Installing rodin-headless $$ver to $(DESTDIR)$(prefix)"; \
	$(INSTALL) -d "$(DESTDIR)$(bindir)"; \
	subst rodin-headless         > "$(DESTDIR)$(bindir)/$(BIN_WRAPPER)"; \
	subst rodin-headless-install > "$(DESTDIR)$(bindir)/$(BIN_INSTALLER)"; \
	chmod 755 "$(DESTDIR)$(bindir)/$(BIN_WRAPPER)" "$(DESTDIR)$(bindir)/$(BIN_INSTALLER)"; \
	$(INSTALL) -d "$(DESTDIR)$(pkglibexecdir)"; \
	for f in $(LIBEXEC_SCRIPTS); do \
	    subst "$$f" > "$(DESTDIR)$(pkglibexecdir)/$$f"; \
	    chmod 755 "$(DESTDIR)$(pkglibexecdir)/$$f"; \
	done; \
	$(INSTALL_DATA) $(LIBEXEC_LIB) "$(DESTDIR)$(pkglibexecdir)/$(LIBEXEC_LIB)"; \
	$(INSTALL_DATA) VERSION "$(DESTDIR)$(pkglibexecdir)/VERSION"; \
	$(INSTALL) -d "$(DESTDIR)$(pkgdatadir)"; \
	for f in $(DATA_FILES); do \
	    $(INSTALL_DATA) "$$f" "$(DESTDIR)$(pkgdatadir)/$$f"; \
	done; \
	for m in rodin-headless.1 rodin-headless-install.1; do \
	    [ -f "$$m" ] || continue; \
	    $(INSTALL) -d "$(DESTDIR)$(man1dir)"; \
	    sed "s|@VERSION@|$$ver_esc|g" "$$m" > "$(DESTDIR)$(man1dir)/$$m"; \
	    chmod 644 "$(DESTDIR)$(man1dir)/$$m"; \
	done

uninstall:
	rm -f "$(DESTDIR)$(bindir)/$(BIN_WRAPPER)" "$(DESTDIR)$(bindir)/$(BIN_INSTALLER)"
	rm -rf "$(DESTDIR)$(pkglibexecdir)"
	rm -rf "$(DESTDIR)$(pkgdatadir)"
	rm -f "$(DESTDIR)$(man1dir)/rodin-headless.1" \
	      "$(DESTDIR)$(man1dir)/rodin-headless-install.1"
