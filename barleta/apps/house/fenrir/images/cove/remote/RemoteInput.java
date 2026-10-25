package games.fenrir.cove;

import java.awt.event.KeyEvent;

/** Pointer gestures sent by Moonlight's Siri Remote, independent of the UI toolkit. */
final class RemoteInput {
    static final long HOLD_MS = 750;
    static final long REPEAT_MS = 160;
    private Integer lastX, lastY;
    private double dx, dy;
    private long lastStep = Long.MIN_VALUE / 2;
    private boolean pressed, held;

    void resetMotion() {
        lastX = lastY = null;
        dx = dy = 0;
    }

    void anchor(int x, int y) {
        lastX = x;
        lastY = y;
        dx = dy = 0;
    }

    int move(int x, int y, long now, int threshold) {
        if (lastX == null) {
            anchor(x, y);
            return 0;
        }
        dx += x - lastX;
        dy += y - lastY;
        lastX = x;
        lastY = y;
        if (pressed || now - lastStep < REPEAT_MS || Math.max(Math.abs(dx), Math.abs(dy)) < threshold) return 0;
        int key = Math.abs(dx) >= Math.abs(dy)
                ? (dx > 0 ? KeyEvent.VK_RIGHT : KeyEvent.VK_LEFT)
                : (dy > 0 ? KeyEvent.VK_DOWN : KeyEvent.VK_UP);
        dx = dy = 0;
        lastStep = now;
        return key;
    }

    boolean press() {
        if (pressed) return false;
        pressed = true;
        held = false;
        return true;
    }

    boolean hold() {
        if (!pressed || held) return false;
        held = true;
        return true;
    }

    boolean release() {
        boolean select = pressed && !held;
        cancel();
        return select;
    }

    void cancel() {
        pressed = held = false;
        resetMotion();
    }
}
