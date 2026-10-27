import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:win32/win32.dart';

import 'device_utils.dart';

/// Windows 窗口样式修复辅助工具。
///
/// window_manager 0.5.2 在 [SetResizable] 后不会调用 SetWindowPos(...SWP_FRAMECHANGED)，
/// 导致 WS_THICKFRAME 样式变更无法立即生效，进而表现为：
/// - 全屏退出后窗口无法调整尺寸；
/// - 小窗模式自定义拉伸热区失效；
/// - 窗口尺寸限制异常。
///
/// 本工具通过 win32 API 直接校验并补充 WS_THICKFRAME，同时刷新窗口框架，
/// 作为插件问题的临时规避方案。
class WindowsWindowUtils {
  WindowsWindowUtils._();

  /// 进入原生全屏前保存的窗口样式（GWL_STYLE），退出时恢复。
  static int _savedStyle = 0;

  /// 进入原生全屏前保存的窗口位置/状态原始字节（WINDOWPLACEMENT），退出时按字节还原。
  ///
  /// win32 6.x 的 Struct 只能在原生内存中分配，不能长期持有 Dart 对象，
  /// 因此把结构体内容按字节拷贝保存。
  static Uint8List? _savedPlacementBytes;

  /// 当前是否处于 Win32 原生真全屏状态。
  ///
  /// 该状态由本类维护，不依赖 window_manager 插件的内部状态，供全屏查询
  /// 统一使用，避免插件状态与实际窗口状态失步。
  static bool _nativeFullScreen = false;

  /// 当前是否处于 Win32 原生真全屏。
  ///
  /// 仅 Windows 上有意义；其它平台恒为 false。
  static bool get isNativeFullScreen => DeviceUtils.isWindows && _nativeFullScreen;

  /// Win32 原生真全屏切换（仅 Windows 生效）。
  ///
  /// 进入全屏：
  /// 1. 保存当前窗口样式与 WINDOWPLACEMENT（含最大化/还原状态与位置）；
  /// 2. 把窗口样式改为 WS_POPUP 并移除 WS_CAPTION/WS_THICKFRAME 等装饰位；
  /// 3. 取窗口所在显示器的 rcMonitor（物理像素），用 SetWindowPos 把窗口
  ///    精确铺满整个显示器并置顶。
  ///
  /// 因为窗口无边框且精确覆盖显示器，Windows Shell 会将其识别为全屏窗口，
  /// 从而自动隐藏任务栏；同时也修复了 window_manager 在 DPI 缩放 != 100% 时
  /// 全屏尺寸计算错误导致“伪全屏”的问题。
  ///
  /// 退出全屏：恢复进入前保存的样式与 WINDOWPLACEMENT，并取消置顶。
  ///
  /// 返回是否成功；失败时内部已回滚窗口样式，不影响后续操作。
  static Future<bool> setNativeFullScreen(bool fullscreen) async {
    if (!DeviceUtils.isWindows) return false;
    try {
      final hwndValue = await windowManager.getId();
      if (hwndValue == 0) {
        debugPrint('WindowsWindowUtils: 无法获取窗口句柄');
        return false;
      }
      final hwnd = HWND(Pointer.fromAddress(hwndValue).cast<NativeType>());

      if (fullscreen) {
        if (_nativeFullScreen) return true; // 已处于原生全屏，幂等返回。

        // win32 6.x 的结构体必须分配在原生内存中，用完后立即释放。
        final pPlacement = calloc<WINDOWPLACEMENT>();
        final pMonitorInfo = calloc<MONITORINFO>();
        try {
          final placementSize = sizeOf<WINDOWPLACEMENT>();

          // 1. 保存窗口位置/状态；若最小化先还原，再重新读取，避免基于最小化状态恢复。
          pPlacement.ref.length = placementSize;
          final gp = GetWindowPlacement(hwnd, pPlacement);
          if (gp.error.isError || !gp.value) {
            debugPrint('WindowsWindowUtils: 读取窗口位置失败，放弃进入原生全屏');
            return false;
          }
          if (pPlacement.ref.showCmd == SW_SHOWMINIMIZED) {
            ShowWindow(hwnd, SW_RESTORE);
            pPlacement.ref.length = placementSize;
            final gp2 = GetWindowPlacement(hwnd, pPlacement);
            if (gp2.error.isError || !gp2.value) {
              debugPrint('WindowsWindowUtils: 还原最小化后读取窗口位置失败');
              return false;
            }
          }
          _savedPlacementBytes = Uint8List.fromList(
            pPlacement.cast<Uint8>().asTypedList(placementSize),
          );

          // 2. 保存并改写窗口样式：WS_POPUP + 去掉标题栏/边框/系统菜单等装饰位。
          final styleResult = GetWindowLongPtr(hwnd, GWL_STYLE);
          if (styleResult.error.isError) {
            debugPrint('WindowsWindowUtils: 获取窗口样式失败');
            return false;
          }
          _savedStyle = styleResult.value;
          final popupStyle = (_savedStyle | WS_POPUP) &
              ~(WS_CAPTION |
                  WS_THICKFRAME |
                  WS_SYSMENU |
                  WS_MINIMIZEBOX |
                  WS_MAXIMIZEBOX);
          SetWindowLongPtr(hwnd, GWL_STYLE, popupStyle);

          // 3. 取所在显示器矩形（物理像素），精确铺满并置顶。
          final monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
          pMonitorInfo.ref.cbSize = sizeOf<MONITORINFO>();
          if (!GetMonitorInfo(monitor, pMonitorInfo)) {
            debugPrint('WindowsWindowUtils: 获取显示器信息失败，回滚样式');
            SetWindowLongPtr(hwnd, GWL_STYLE, _savedStyle);
            return false;
          }
          final rc = pMonitorInfo.ref.rcMonitor;
          final sp = SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            rc.left,
            rc.top,
            rc.right - rc.left,
            rc.bottom - rc.top,
            SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
          );
          if (sp.error.isError || !sp.value) {
            debugPrint('WindowsWindowUtils: 全屏 SetWindowPos 失败，回滚样式');
            SetWindowLongPtr(hwnd, GWL_STYLE, _savedStyle);
            SetWindowPos(
              hwnd,
              HWND_NOTOPMOST,
              0,
              0,
              0,
              0,
              SWP_NOMOVE |
                  SWP_NOSIZE |
                  SWP_NOZORDER |
                  SWP_NOOWNERZORDER |
                  SWP_FRAMECHANGED,
            );
            return false;
          }
          _nativeFullScreen = true;
          debugPrint('WindowsWindowUtils: 已进入 Win32 原生真全屏 '
              '(${rc.right - rc.left}x${rc.bottom - rc.top})');
          return true;
        } finally {
          calloc.free(pPlacement);
          calloc.free(pMonitorInfo);
        }
      } else {
        if (!_nativeFullScreen) return true; // 本就不在原生全屏，幂等返回。

        // 1. 恢复进入前的窗口样式并取消置顶。
        if (_savedStyle != 0) {
          SetWindowLongPtr(hwnd, GWL_STYLE, _savedStyle);
        }
        SetWindowPos(
          hwnd,
          HWND_NOTOPMOST,
          0,
          0,
          0,
          0,
          SWP_NOMOVE |
              SWP_NOSIZE |
              SWP_NOZORDER |
              SWP_NOOWNERZORDER |
              SWP_FRAMECHANGED,
        );

        // 2. 恢复进入前的窗口位置/状态（含最大化状态与还原位置）。
        final savedBytes = _savedPlacementBytes;
        if (savedBytes != null) {
          final pPlacement = calloc<WINDOWPLACEMENT>();
          try {
            final placementSize = sizeOf<WINDOWPLACEMENT>();
            if (savedBytes.length >= placementSize) {
              pPlacement
                  .cast<Uint8>()
                  .asTypedList(placementSize)
                  .setAll(0, savedBytes);
              final sp2 = SetWindowPlacement(hwnd, pPlacement);
              if (sp2.error.isError || !sp2.value) {
                debugPrint('WindowsWindowUtils: 恢复窗口位置失败，兜底最大化窗口');
                ShowWindow(hwnd, SW_MAXIMIZE);
              }
            } else {
              ShowWindow(hwnd, SW_MAXIMIZE);
            }
          } finally {
            calloc.free(pPlacement);
          }
        } else {
          ShowWindow(hwnd, SW_MAXIMIZE);
        }
        _savedPlacementBytes = null;
        _savedStyle = 0;
        _nativeFullScreen = false;
        debugPrint('WindowsWindowUtils: 已退出 Win32 原生真全屏');
        return true;
      }
    } catch (e) {
      debugPrint('WindowsWindowUtils: 原生全屏切换失败: $e');
      if (!fullscreen) {
        _nativeFullScreen = false;
      }
      return false;
    }
  }

  /// 确保当前窗口具有可调整尺寸边框（WS_THICKFRAME）并刷新框架。
  ///
  /// window_manager 的 [SetResizable] 仅修改 GWL_STYLE，不会调用
  /// SetWindowPos(...SWP_FRAMECHANGED)，导致 WS_THICKFRAME 变更不会立即生效。
  /// 本方法主动补充 WS_THICKFRAME 并始终刷新框架，确保样式立即生效。
  static Future<void> ensureResizableFrame() async {
    if (!DeviceUtils.isWindows) return;
    try {
      final hwndValue = await windowManager.getId();
      if (hwndValue == 0) {
        debugPrint('WindowsWindowUtils: 无法获取窗口句柄');
        return;
      }
      final hwnd = HWND(Pointer.fromAddress(hwndValue).cast<NativeType>());
      final styleResult = GetWindowLongPtr(hwnd, GWL_STYLE);
      if (styleResult.error.isError) {
        debugPrint('WindowsWindowUtils: 获取窗口样式失败');
        return;
      }
      final style = styleResult.value;
      final newStyle = style | WS_THICKFRAME;
      if (newStyle != style) {
        SetWindowLongPtr(hwnd, GWL_STYLE, newStyle);
        debugPrint('WindowsWindowUtils: 已补充 WS_THICKFRAME');
      }
      SetWindowPos(
        hwnd,
        HWND_TOP,
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
      );
      debugPrint('WindowsWindowUtils: 已刷新窗口框架');
    } catch (e) {
      debugPrint('WindowsWindowUtils: 确保可调整尺寸失败: $e');
    }
  }

  /// 将窗口样式恢复为普通可调整尺寸窗口（补充标题栏、系统菜单、最大/最小化框）。
  ///
  /// 当窗口曾因全屏/小窗切换丢失 WS_CAPTION/WS_THICKFRAME 等样式时，
  /// 调用本方法可确保后续 setFullScreen/setBounds 等操作基于正常窗口状态，
  /// 避免退出全屏或恢复小窗后变成不可调整的小窗口。
  static Future<void> ensureNormalWindowFrame() async {
    if (!DeviceUtils.isWindows) return;
    try {
      final hwndValue = await windowManager.getId();
      if (hwndValue == 0) {
        debugPrint('WindowsWindowUtils: 无法获取窗口句柄');
        return;
      }
      final hwnd = HWND(Pointer.fromAddress(hwndValue).cast<NativeType>());
      final styleResult = GetWindowLongPtr(hwnd, GWL_STYLE);
      if (styleResult.error.isError) {
        debugPrint('WindowsWindowUtils: 获取窗口样式失败');
        return;
      }
      final style = styleResult.value;
      final normalStyle = WS_CAPTION | WS_SYSMENU | WS_THICKFRAME |
          WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
      final newStyle = style | normalStyle;
      if (newStyle != style) {
        SetWindowLongPtr(hwnd, GWL_STYLE, newStyle);
        debugPrint('WindowsWindowUtils: 已恢复普通窗口样式');
      }
      SetWindowPos(
        hwnd,
        HWND_TOP,
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
      );
      debugPrint('WindowsWindowUtils: 已刷新普通窗口框架');
    } catch (e) {
      debugPrint('WindowsWindowUtils: 恢复普通窗口样式失败: $e');
    }
  }

  /// 控制鼠标光标可见性（仅 Windows）。
  ///
  /// [visible] 为 true 显示光标，false 隐藏光标。底层基于 win32 的 ShowCursor
  /// 计数器 API：隐藏时持续递减计数直到光标真正隐藏，显示时持续递增直到真正显示，
  /// 避免多次调用造成计数不平衡导致光标无法恢复。
  static void setCursorVisible(bool visible) {
    if (!DeviceUtils.isWindows) return;
    try {
      if (visible) {
        // 递增计数直到光标可见（ShowCursor 返回计数 >= 0 表示可见）。
        while (ShowCursor(true) < 0) {}
      } else {
        // 递减计数直到光标隐藏（ShowCursor 返回计数 < 0 表示隐藏）。
        while (ShowCursor(false) >= 0) {}
      }
    } catch (e) {
      debugPrint('WindowsWindowUtils: 设置光标可见性失败: $e');
    }
  }

  /// 刷新窗口框架，使之前的样式变更（如 setResizable）立即生效。
  static Future<void> refreshWindowFrame() async {
    if (!DeviceUtils.isWindows) return;
    try {
      final hwndValue = await windowManager.getId();
      if (hwndValue == 0) return;
      final hwnd = HWND(Pointer.fromAddress(hwndValue).cast<NativeType>());
      SetWindowPos(
        hwnd,
        HWND_TOP,
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
      );
    } catch (e) {
      debugPrint('WindowsWindowUtils: 刷新窗口框架失败: $e');
    }
  }
}
