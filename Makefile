export ARCHS = arm64 arm64e
export TARGET ?= iphone:clang
export TARGET_OS_DEPLOYMENT_VERSION ?= 15.0
export THEOS_PACKAGE_SCHEME ?= roothide

export DEBUG = 0
export GO_EASY_ON_ME = 1

# Use the control version even when building without FINALPACKAGE.
PACKAGE_VERSION ?= $(THEOS_PACKAGE_BASE_VERSION)

ifeq ($(filter $(THEOS_PACKAGE_SCHEME),roothide rootless),)
$(error Set THEOS_PACKAGE_SCHEME to roothide (default) or rootless)
endif

# CI can select the SDK with SDKVERSION or TARGET and provide an SDK with
# the private Preferences.framework stub. Use the pinned roothide/theos.
include $(THEOS)/makefiles/common.mk

SUBPROJECTS += FlatGlassIconServices FlatGlassRefresh FlatGlassPrefs flatglass

include $(THEOS_MAKE_PATH)/aggregate.mk

FG_DAEMON_PLIST = $(THEOS_STAGING_DIR)/Library/LaunchDaemons/local.lumid.flatglass.plist

# The native layout is already correct for RootHide. For traditional rootless,
# prefix paths inside the staged templates; Theos moves the payload itself.
internal-stage::
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	@p="$(FG_DAEMON_PLIST)"; sed 's|<string>/usr/libexec/flatglass</string>|<string>$(THEOS_PACKAGE_INSTALL_PREFIX)/usr/libexec/flatglass</string>|' "$$p" > "$$p.tmp" && mv "$$p.tmp" "$$p"
endif
	@chmod 0644 "$(FG_DAEMON_PLIST)"

# Theos copies DEBIAN and writes its control in the preceding before-package rule.
before-package::
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	@set -e; for script in postinst prerm; do \
		p="$(THEOS_STAGING_DIR)/DEBIAN/$$script"; \
		sed "s|^prefix=''$$|prefix='$(THEOS_PACKAGE_INSTALL_PREFIX)'|" "$$p" > "$$p.tmp"; \
		mv "$$p.tmp" "$$p"; \
	done
	@p="$(THEOS_STAGING_DIR)/DEBIAN/control"; sed '/^Depends:/s/, roothide$$//' "$$p" > "$$p.tmp" && mv "$$p.tmp" "$$p"
endif
	@chmod 0644 "$(THEOS_STAGING_DIR)/DEBIAN/control"
	@chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/prerm"
