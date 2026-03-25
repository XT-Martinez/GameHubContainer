CC      ?= gcc
CFLAGS  := -Wall -Wextra -Wno-unused-parameter -O2
LDLIBS_SHIM := -ldl

SHIM    := libuinput_shim.so
DAEMON  := input-mknod-daemon
PREFIX  ?= /usr/local

.PHONY: all clean install uninstall

all: $(SHIM) $(DAEMON)

$(SHIM): uinput_shim.c
	$(CC) $(CFLAGS) -fPIC -shared -o $@ $< $(LDLIBS_SHIM)

$(DAEMON): input_mknod_daemon.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(SHIM) $(DAEMON)

install: $(SHIM) $(DAEMON)
	install -Dm755 $(SHIM) $(DESTDIR)$(PREFIX)/lib/$(SHIM)
	install -Dm755 $(DAEMON) $(DESTDIR)$(PREFIX)/bin/$(DAEMON)
	install -Dm644 99-sunshine-container-ignore.rules \
		$(DESTDIR)/etc/udev/rules.d/99-sunshine-container-ignore.rules

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/lib/$(SHIM)
	rm -f $(DESTDIR)$(PREFIX)/bin/$(DAEMON)
	rm -f $(DESTDIR)/etc/udev/rules.d/99-sunshine-container-ignore.rules
