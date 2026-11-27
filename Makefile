export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

export DEBUG = 0
export GO_EASY_ON_ME = 1

SUBPROJECTS += FlatGlassIconServices
SUBPROJECTS += FlatGlassRefresh
SUBPROJECTS += FlatGlassPrefs
SUBPROJECTS += flatglass

include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 iconservicesagent; killall -9 SpringBoard" || true
