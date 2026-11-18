.PHONY: build test run clean package

DEVDIR := $(shell xcode-select -p)
TEST_FLAGS :=

# Command Line Tools ships Swift Testing in a nonstandard location; Xcode does not.
ifeq ($(DEVDIR),/Library/Developer/CommandLineTools)
TEST_FLAGS := \
	-Xswiftc -plugin-path -Xswiftc $(DEVDIR)/usr/lib/swift/host/plugins/testing \
	-Xswiftc -F -Xswiftc $(DEVDIR)/Library/Developer/Frameworks \
	-Xlinker -F -Xlinker $(DEVDIR)/Library/Developer/Frameworks \
	-Xlinker -framework -Xlinker Testing \
	-Xlinker -rpath -Xlinker $(DEVDIR)/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker $(DEVDIR)/Library/Developer/usr/lib
endif

build: package

package:
	./scripts/package-app.sh

test:
	swift test $(TEST_FLAGS)

run: package
	open dist/sn-monitor.app

clean:
	rm -rf .build dist
