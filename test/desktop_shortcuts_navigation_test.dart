import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:privatelm/controllers/home_controller.dart';
import 'package:privatelm/controllers/chat_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Desktop Shortcuts & Navigation Unit Tests', () {
    late HomeController homeController;

    setUp(() {
      Get.reset();
      homeController = Get.put(HomeController());
    });

    tearDown(() {
      Get.reset();
    });

    test('HomeController default tab is 0 (Chat)', () {
      expect(homeController.currentTab.value, 0);
      expect(homeController.isSidebarVisible.value, true);
    });

    test('HomeController changeTab switches tabs correctly for numeric shortcuts', () {
      // Ctrl+1: Chat
      homeController.changeTab(0);
      expect(homeController.currentTab.value, 0);

      // Ctrl+2: Models
      homeController.changeTab(1);
      expect(homeController.currentTab.value, 1);

      // Ctrl+3: Server
      homeController.changeTab(2);
      expect(homeController.currentTab.value, 2);

      // Ctrl+4 / Ctrl+,: Settings
      homeController.changeTab(3);
      expect(homeController.currentTab.value, 3);
    });

    test('HomeController toggleSidebar toggles desktop sidebar rail visibility when no drawer active', () {
      expect(homeController.isSidebarVisible.value, true);

      // First toggle (Ctrl+B / Cmd+B)
      homeController.toggleSidebar();
      expect(homeController.isSidebarVisible.value, false);

      // Second toggle restores visibility
      homeController.toggleSidebar();
      expect(homeController.isSidebarVisible.value, true);
    });
  });
}
