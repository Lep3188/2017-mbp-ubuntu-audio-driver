# Convenience wrapper; install.sh is the real interface.

.PHONY: all build install uninstall doctor verify tone clean help

all: build

help:
	@echo "make build      - unprivileged build into ./build"
	@echo "make install    - build and install (needs sudo)"
	@echo "make uninstall  - remove the driver"
	@echo "make doctor     - diagnose the audio stack"
	@echo "make verify     - post-reboot checks"
	@echo "make tone       - play a test tone (LOUD)"
	@echo "make clean      - remove build artefacts"

build:
	./install.sh --build-only "$(CURDIR)/build"

install:
	sudo ./install.sh

uninstall:
	sudo ./uninstall.sh

doctor:
	./scripts/doctor.sh

verify:
	./scripts/verify.sh

tone:
	./scripts/verify.sh --tone

clean:
	rm -rf build .cache
