THEOS ?= /Users/xnu/sec/jailbreak/toolchains/theos-roothide
THEOS_PACKAGE_SCHEME = roothide
TARGET = iphone:clang:latest:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = BeanBao
BeanBao_FILES = main.m ../agent-native/AgentClient.m
BeanBao_CFLAGS = -fobjc-arc -Wall -Wextra -I../agent-native
BeanBao_FRAMEWORKS = UIKit Foundation Speech AVFoundation
BeanBao_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
