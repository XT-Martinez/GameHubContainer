CC      ?= gcc
CFLAGS  := -Wall -Wextra -Wno-unused-parameter -O2
LDLIBS_SHIM := -ldl

SHIM64  := libuinput_shim.so
SHIM32  := libuinput_shim32.so
DAEMON  := input-mknod-daemon
PREFIX  ?= /usr/local

.PHONY: all clean install uninstall

all: $(SHIM64) $(SHIM32) $(DAEMON)

$(SHIM64): uinput_shim.c
	$(CC) $(CFLAGS) -fPIC -shared -o $@ $< $(LDLIBS_SHIM)

$(SHIM32): uinput_shim.c
	$(CC) $(CFLAGS) -m32 -fPIC -shared -o $@ $< $(LDLIBS_SHIM)

$(DAEMON): input_mknod_daemon.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(SHIM64) $(SHIM32) $(DAEMON)

install: $(SHIM64) $(SHIM32) $(DAEMON)
	install -Dm755 $(SHIM64) $(DESTDIR)$(PREFIX)/lib64/libuinput_shim.so
	install -Dm755 $(SHIM32) $(DESTDIR)$(PREFIX)/lib/libuinput_shim.so
	install -Dm755 $(DAEMON) $(DESTDIR)$(PREFIX)/bin/$(DAEMON)
	install -Dm644 99-sunshine-container-ignore.rules \
		$(DESTDIR)/etc/udev/rules.d/99-sunshine-container-ignore.rules

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/lib64/libuinput_shim.so
	rm -f $(DESTDIR)$(PREFIX)/lib/libuinput_shim.so
	rm -f $(DESTDIR)$(PREFIX)/bin/$(DAEMON)
	rm -f $(DESTDIR)/etc/udev/rules.d/99-sunshine-container-ignore.rules
