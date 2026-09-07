# ============================================================================
# OneStep for iOS —— 锤子科技「一步」交互的越狱移植（Theos / Logos）
#
# 目标环境：iOS 15.0+，rootless（/var/jb 布局），ElleKit 注入
#           （Dopamine / palera1n(rootless) / Relaxin(RootHide) 等）
#
# 工程内含两个注入器（两个 dylib，装成一个 deb）：
#   OneStepUI     —— 只注入 SpringBoard：手势、侧边栏、顶部托盘、拖放编排
#   OneStepPaster —— 注入所有 App 进程：自动粘贴助手、剪贴板写操作上报
#
# 依赖注入器 filter 见工程根：OneStepUI.plist / OneStepPaster.plist
# ============================================================================

export TARGET            = iphone:clang:latest:15.0
export ARCHS             = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless
export DEBUG             = 0
export FINALPACKAGE      = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OneStepUI OneStepPaster

# ----------------------------------------------------------------------------
# OneStepUI —— SpringBoard 侧（窗口 / 手势 / 界面 / 拖放）
# ----------------------------------------------------------------------------
OneStepUI_FILES = $(wildcard src/Shared/*.m) \
                  $(wildcard src/OneStepUI/*.xm) \
                  $(wildcard src/OneStepUI/*.m)
OneStepUI_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/src -I$(THEOS_PROJECT_DIR)/src/Shared
OneStepUI_CFLAGS += -Wno-deprecated-declarations
OneStepUI_LIBRARIES =
OneStepUI_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
# Photos / Contacts / AddressBook / UserNotifications 走 runtime 动态加载，不静态链接

# ----------------------------------------------------------------------------
# OneStepPaster —— 各 App 进程（自动粘贴 / 剪贴板上报）
# ----------------------------------------------------------------------------
OneStepPaster_FILES = $(wildcard src/Shared/*.m) \
                      $(wildcard src/OneStepPaster/*.xm) \
                      $(wildcard src/OneStepPaster/*.m)
OneStepPaster_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/src -I$(THEOS_PROJECT_DIR)/src/Shared
OneStepPaster_CFLAGS += -Wno-deprecated-declarations
OneStepPaster_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

# 共享代码里没有需要 ARC 外的特殊处理
ADDITIONAL_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

before-package::
	@echo "==> OneStep for iOS 打包前检查：确保 layout 默认偏好已就位"

after-install::
	install.exec "killall -9 SpringBoard"
	@echo "==> 已重启 SpringBoard，OneStep 生效。"
