THEOS ?= $(HOME)/theos
THEOS_PACKAGE_SCHEME = roothide
TARGET = iphone:clang:latest:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = BeanBao
BeanBao_FILES = main.m ModelSettingsViewController.m ActivityStore.m ActivityViewController.m WorkflowSessionsViewController.m WorkflowDetailViewController.m ../agent-native/AgentClient.m ../agent-native/ModelConfig.m ../common/VoiceIPC.m LocalDictation.swift
BeanBao_CFLAGS = -fobjc-arc -Wall -Wextra -I../agent-native -I../common
BeanBao_FRAMEWORKS = UIKit Foundation Speech AVFoundation QuickLook MessageUI StoreKit WebKit
BeanBao_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
