THEOS ?= $(HOME)/theos
THEOS_PACKAGE_SCHEME = roothide
TARGET = iphone:clang:latest:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = BeanBaoDelivery
BeanBaoDelivery_FILES = main.m ../app/DeliveryBrowserViewController.m ../agent-native/AgentClient.m
BeanBaoDelivery_CFLAGS = -fobjc-arc -Wall -Wextra -I../app -I../agent-native
BeanBaoDelivery_FRAMEWORKS = UIKit Foundation WebKit
BeanBaoDelivery_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
