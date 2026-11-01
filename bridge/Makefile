THEOS ?= /Users/xnu/sec/jailbreak/toolchains/theos-roothide
THEOS_PACKAGE_SCHEME = roothide
TARGET = iphone:clang:latest:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BeanBaoBridge
TOOL_NAME = beanbaoctl
BeanBaoBridge_FILES = Tweak.x BeanBaoBridge.m BeanBaoApp.m BBQuickOverlay.m ../agent-native/AgentClient.m MCPLogger.m \
  ../vendor/ios-mcp/HIDManager.m ../vendor/ios-mcp/ScreenManager.m \
  ../vendor/ios-mcp/AccessibilityManager.m ../vendor/ios-mcp/TextInputManager.m \
  ../vendor/ios-mcp/VisionOCREngine.m ../vendor/ios-mcp/MCPAXQueryContext.m \
  ../vendor/ios-mcp/MCPAXRemoteContextResolver.m ../vendor/ios-mcp/MCPUIElementSerializer.m \
  ../vendor/ios-mcp/MCPUIElementsFacade.m ../vendor/ios-mcp/MCPAXAttributeBridge.m \
  ../vendor/ios-mcp/MCPAXNodeSource.m
BeanBaoBridge_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -I../vendor/ios-mcp -I../agent-native
BeanBaoBridge_FRAMEWORKS = UIKit CoreGraphics QuartzCore IOKit Vision Security
BeanBaoBridge_LIBRARIES = roothide
BeanBaoBridge_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
beanbaoctl_FILES = beanbaoctl.m
beanbaoctl_CFLAGS = -fobjc-arc
beanbaoctl_FRAMEWORKS = Foundation
beanbaoctl_CODESIGN_FLAGS = -Sbeanbaoctl_entitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/usr/share/doc/beanbao"
	@cp ../vendor/ios-mcp/LICENSE "$(THEOS_STAGING_DIR)/usr/share/doc/beanbao/ios-mcp-LICENSE"
	@cp ../vendor/ios-mcp/NOTICE "$(THEOS_STAGING_DIR)/usr/share/doc/beanbao/ios-mcp-NOTICE"
