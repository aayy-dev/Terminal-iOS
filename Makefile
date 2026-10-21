export TARGET = iphone:latest:14.0
export ARCHS = arm64

ifeq ($(ROOTLESS),1)
	export DEB_ARCH = iphoneos-arm64
	export INSTALL_PREFIX = /var/jb
else
	export DEB_ARCH = iphoneos-arm
endif

include $(THEOS)/makefiles/common.mk

# Theos names the package and writes its Architecture field from this.
override THEOS_PACKAGE_ARCH := $(DEB_ARCH)

XCODEPROJ_NAME = NewTerm

NewTerm_XCODE_SCHEME = NewTerm (iOS)
# The app's version, and the name and identifier in Settings, come from control, so a fork only
# changes them there.
control_field = $(shell grep -i '^$(1):' control | cut -d' ' -f2-)
NewTerm_XCODEFLAGS = INSTALL_PREFIX=$(INSTALL_PREFIX) \
	MARKETING_VERSION='$(call control_field,Version)' \
	DEB_PACKAGE_NAME='$(call control_field,Name)' \
	DEB_PACKAGE_ID='$(call control_field,Package)'
NewTerm_CODESIGN_FLAGS = -SApp/entitlements.plist
NewTerm_INSTALL_PATH = $(INSTALL_PREFIX)/Applications

include $(THEOS_MAKE_PATH)/xcodeproj.mk

after-stage::
	@$(TARGET_CODESIGN) $(NewTerm_CODESIGN_FLAGS) $(THEOS_STAGING_DIR)$(INSTALL_PREFIX)/Applications/Terminal.app/TerminalLoginHelper
	@mkdir -p "$(THEOS_STAGING_DIR)$(INSTALL_PREFIX)/usr/share/doc/$(call control_field,Package)"
	@cp LICENSE.md "$(THEOS_STAGING_DIR)$(INSTALL_PREFIX)/usr/share/doc/$(call control_field,Package)/"

# iSH's process is also called Terminal, so stop the app by its path rather than with killall.
after-install::
	install.exec "ps -ax -o pid=,comm= | grep '/Terminal.app/Terminal$$' | sed 's/^ *//; s/ .*//' | xargs kill -9 2>/dev/null; true"
