THEOS ?= /Users/xnu/sec/jailbreak/toolchains/theos-roothide
THEOS_PACKAGE_SCHEME = roothide
TARGET = iphone:clang:latest:17.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = beanbaod
TOOL_NAME += beanbaoagentctl
beanbaod_FILES = beanbaod.m AgentService.m BBAudit.m ModelConfig.m $(wildcard ../harness/*.swift) \
	$(wildcard ../vendor/palmino-harness-runtime/Sources/AgentRuntime/*.swift) \
	$(wildcard ../vendor/palmino-harness-runtime/Sources/AgentTools/*.swift)
beanbaod_SWIFT_VERSION = 6
beanbaod_CFLAGS = -fobjc-arc -Wall -Wextra
beanbaod_FRAMEWORKS = Foundation CoreGraphics CoreText
beanbaod_CODESIGN_FLAGS = -S../bridge/beanbaoctl_entitlements.plist
beanbaoagentctl_FILES = beanbaoagentctl.m AgentClient.m
beanbaoagentctl_CFLAGS = -fobjc-arc -Wall -Wextra
beanbaoagentctl_FRAMEWORKS = Foundation
beanbaoagentctl_CODESIGN_FLAGS = -S../bridge/beanbaoctl_entitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
