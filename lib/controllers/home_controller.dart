import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../core/haptics.dart';

class HomeController extends GetxController {
  final currentTab = 0.obs;

  /// Root scaffold key — the chat sidebar hangs off the root so it slides
  /// over the bottom navigation bar instead of under it.
  final scaffoldKey = GlobalKey<ScaffoldState>();

  /// Controls visibility of the desktop sidebar rail.
  final isSidebarVisible = true.obs;

  void changeTab(int index) {
    if (currentTab.value != index) {
      Haptics.selectionClick();
      currentTab.value = index;
    }
  }

  void openSidebar() => scaffoldKey.currentState?.openDrawer();

  void closeSidebar() => scaffoldKey.currentState?.closeDrawer();

  void toggleSidebar() {
    Haptics.selectionClick();
    if (scaffoldKey.currentState?.hasDrawer == true) {
      if (scaffoldKey.currentState?.isDrawerOpen == true) {
        closeSidebar();
      } else {
        openSidebar();
      }
    } else {
      isSidebarVisible.value = !isSidebarVisible.value;
    }
  }
}

