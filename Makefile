# ============================================================================
# OneStep Split (v0.3) —— iPhone 分屏越狱插件（Theos / Logos）
#
# 目标环境：iOS 15+，rootless（/var/jb），ElleKit 注入，单 dylib 仅注入
#          SpringBoard（filter 见 OneStepUI.plist）。
#
# 功能：全屏主 App + scene-host 实时小浮窗，点小窗切换主副（P0 最小闭环）。
# ============================================================================

export TARGET            = iphone:clang:latest:15.0
export ARCHS             = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless
export DEBUG             = 0
export FINALPACKAGE      = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OneStepUI

OneStepUI_FILES = $(wildcard src/OneStepUI/*.xm) \
                  $(wildcard src/OneStepUI/*.m)
OneStepUI_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
OneStepUI_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
	@echo "==> OneStep Split 已生效（重启 SpringBoard）。"
