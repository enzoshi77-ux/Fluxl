# Theos path (macOS with the iPhoneOS SDK installed). build.sh is the path for
# any host with clang + ld64.lld and no SDK; this Makefile exists for people
# already set up with Theos.
TARGET = iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = NullsBrawl

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NullsBotFill
NullsBotFill_FILES = NullsBotFill.m
NullsBotFill_CFLAGS = -fobjc-arc -fblocks -Wno-unused-parameter
NullsBotFill_LOGOS = 0

include $(THEOS_MAKE_PATH)/tweak.mk
