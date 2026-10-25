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
        input.recenter(1918, 540, 960, 540, 1500);
        check(input.move(1919, 540, 1505, 30) == 0, "ignore stale edge events queued before recentering");
        check(input.move(1000, 540, 1510, 30) == KeyEvent.VK_RIGHT,
                "coalesced recenter plus swipe works without an exact center event");
        check(!input.isRecentering(), "coalesced movement acknowledges recentering");
        input.recenter(1918, 540, 960, 540, 1700);
        check(input.move(1919, 540, 1830, 30) == 0, "a missing recenter event times out without a phantom direction");
        check(!input.isRecentering() && input.recenterTimeouts() == 1, "missing acknowledgement cannot lock out future swipes");
        check(input.move(1870, 540, 1840, 30) == KeyEvent.VK_LEFT, "swipes resume after a dropped recenter event");
        input.recenter(5, 540, 960, 540, 2000);
        input.cancel();
        check(!input.isRecentering(), "click release or focus loss clears pending recentering");
        input.anchor(500, 500);
        check(input.move(520, 500, 2200, 30) == 0, "small movement remains below threshold");
        check(input.move(480, 500, 2210, 30) == KeyEvent.VK_LEFT, "reversing a swipe does not fight stale movement");
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
