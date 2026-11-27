#
#  FlatGlass 1.8.4 — reconstructed Theos project
#
#  Builds four artifacts, matching the shipped package one for one:
#
#    FlatGlassIconServices  -> injects iconservicesagent (the actual rendering)
#    FlatGlassRefresh       -> injects SpringBoard (reloads visible icons)
#    flatglass              -> LaunchDaemon, bridges prefs to the notify chain
#    FlatGlassPrefs         -> preference bundle
#
#  Rootless by default. For a rootful build use:
#      make clean package THEOS_PACKAGE_SCHEME=
#  For RootHide, use roothide/theos and THEOS_PACKAGE_SCHEME=roothide.
#

export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export DEBUG = 0
export FINALPACKAGE = 1

export THEOS_PACKAGE_SCHEME ?= rootless
ifneq ($(THEOS_PACKAGE_SCHEME),)
ifneq ($(THEOS_PACKAGE_SCHEME),rootless)
ifneq ($(THEOS_PACKAGE_SCHEME),roothide)
$(error FlatGlass supports THEOS_PACKAGE_SCHEME=rootless, roothide, or an empty scheme for rootful)
endif
endif
endif

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += FlatGlassIconServices
SUBPROJECTS += FlatGlassRefresh
SUBPROJECTS += flatglass
SUBPROJECTS += FlatGlassPrefs

include $(THEOS_MAKE_PATH)/aggregate.mk

# Stage under Library/, not var/jb/Library/: Theos moves the payload into the
# selected install prefix later. Embedded absolute paths do need that prefix.
after-stage::
	$(ECHO_NOTHING)python3 "$(THEOS_PROJECT_DIR)/tools/stage_launchd_plist.py" --scheme="$(THEOS_PACKAGE_SCHEME)" --prefix="$(THEOS_PACKAGE_INSTALL_PREFIX)" "$(THEOS_STAGING_DIR)"$(ECHO_END)

before-package::
	$(ECHO_NOTHING)python3 "$(THEOS_PROJECT_DIR)/tools/stage_launchd_plist.py" --control --scheme="$(THEOS_PACKAGE_SCHEME)" --prefix="$(THEOS_PACKAGE_INSTALL_PREFIX)" "$(THEOS_STAGING_DIR)"$(ECHO_END)

after-install::
	install.exec "killall -9 iconservicesagent SpringBoard 2>/dev/null || true"
