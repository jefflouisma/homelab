package games.fenrir.cove;

import java.awt.event.KeyEvent;

/** Regression checks for gesture noise, repeat, direction changes and hold release. */
public final class RemoteInputTest {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    public static void main(String[] arguments) {
        RemoteInput input = new RemoteInput();
        check(input.move(100, 100, 0, 30) == 0, "first position anchors");
        check(input.move(110, 105, 10, 30) == 0, "ignore touch jitter");
        check(input.move(140, 108, 20, 30) == KeyEvent.VK_RIGHT, "accumulate a right swipe");
        check(input.move(190, 108, 50, 30) == 0, "limit repeat rate");
        check(input.move(220, 108, 200, 30) == KeyEvent.VK_RIGHT, "continuous swipe repeats");
        check(input.move(220, 160, 400, 30) == KeyEvent.VK_DOWN, "change direction");
        check(input.press(), "start a center press");
        check(!input.press(), "ignore duplicate presses");
        check(input.move(100, 20, 600, 30) == 0, "holding cannot navigate");
        check(input.release(), "short center press selects once");
        check(!input.release(), "duplicate release cannot select");
        input.press();
        check(input.hold(), "holding opens controls");
        check(!input.hold(), "hold fires once");
        check(!input.release(), "release after hold cannot activate a menu item");
        input.press();
        input.cancel();
        check(!input.release() && !input.hold(), "losing focus cancels a press");
        input.anchor(900, 500);
        check(input.move(870, 500, 1000, 30) == KeyEvent.VK_LEFT, "recenter does not reverse direction");
        input.resetMotion();
        check(input.move(5, 5, 1300, 30) == 0, "new window cannot inherit a swipe");
        int[] backs = {0};
        check(!CoveRemoteLauncher.handleBack(), "no callback after leaving a screen");
        Runnable first = CoveRemoteLauncher.registerBackHandler(() -> backs[0]++);
        Runnable second = CoveRemoteLauncher.registerBackHandler(() -> backs[0] += 10);
        check(CoveRemoteLauncher.handleBack() && backs[0] == 10, "the top Back handler wins");
        first.run();
        check(CoveRemoteLauncher.handleBack() && backs[0] == 20, "disposing a parent preserves the active handler");
        second.run();
        check(!CoveRemoteLauncher.handleBack(), "disposing a screen removes its Back action");
        System.out.println("PASS remote gesture and hold regressions");
    }
}
