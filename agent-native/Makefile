THEOS ?= /Users/xnu/sec/jailbreak/toolchains/theos-roothide
THEOS_PACKAGE_SCHEME = roothide
TARGET = iphone:clang:latest:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = beanbaod
TOOL_NAME += beanbaoagentctl
beanbaod_FILES = beanbaod.m AgentService.m
beanbaod_CFLAGS = -fobjc-arc -Wall -Wextra
beanbaod_FRAMEWORKS = Foundation
beanbaod_CODESIGN_FLAGS = -S../bridge/beanbaoctl_entitlements.plist
beanbaoagentctl_FILES = beanbaoagentctl.m AgentClient.m
beanbaoagentctl_CFLAGS = -fobjc-arc -Wall -Wextra
beanbaoagentctl_FRAMEWORKS = Foundation
beanbaoagentctl_CODESIGN_FLAGS = -S../bridge/beanbaoctl_entitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
