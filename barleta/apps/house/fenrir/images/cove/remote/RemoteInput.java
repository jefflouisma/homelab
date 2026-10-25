package games.fenrir.cove;

import java.awt.event.KeyEvent;

/** Pointer gestures sent by Moonlight's Siri Remote, independent of the UI toolkit. */
final class RemoteInput {
    static final long HOLD_MS = 750;
    static final long REPEAT_MS = 120;
    static final long RECENTER_TIMEOUT_MS = 120;
    private static final long MOTION_IDLE_MS = 200;
    private Integer lastX, lastY;
    private double dx, dy;
    private long lastStep = Long.MIN_VALUE / 2;
    private long lastMotion = Long.MIN_VALUE / 2;
    private boolean recentering;
    private int recenterX, recenterY, originX, originY;
    private long recenterStarted;
    private int recenterTimeouts;
    private boolean pressed, held;

    void resetMotion() {
        lastX = lastY = null;
        dx = dy = 0;
        recentering = false;
    }

    void anchor(int x, int y) {
        lastX = x;
        lastY = y;
        dx = dy = 0;
        recentering = false;
    }

    void recenter(int fromX, int fromY, int toX, int toY, long now) {
        anchor(toX, toY);
        originX = fromX;
        originY = fromY;
        recenterX = toX;
        recenterY = toY;
        recenterStarted = now;
        recentering = true;
    }

    boolean isRecentering() { return recentering; }
    int recenterTimeouts() { return recenterTimeouts; }

    int move(int x, int y, long now, int threshold) {
        if (recentering) {
            // AWT coalesces pointer events: the exact warp coordinate can be replaced
            // by the next swipe position. Accept motion nearer the new anchor, while
            // rejecting old edge events already queued before Robot.mouseMove().
            double toTarget = Math.hypot((double) x - recenterX, (double) y - recenterY);
            double toOrigin = Math.hypot((double) x - originX, (double) y - originY);
            if (toTarget < toOrigin) {
                recentering = false;
            } else if (now - recenterStarted >= RECENTER_TIMEOUT_MS) {
                recenterTimeouts++;
                anchor(x, y);
                lastMotion = now;
                return 0;
            } else return 0;
        }
        if (lastX == null) {
            anchor(x, y);
            lastMotion = now;
            return 0;
        }
        int movementX = x - lastX, movementY = y - lastY;
        if (now - lastMotion > MOTION_IDLE_MS) dx = dy = 0;
        // A reversal starts a new direction instead of fighting unused old movement.
        if (dx * movementX < 0) dx = 0;
        if (dy * movementY < 0) dy = 0;
        dx += movementX;
        dy += movementY;
        lastX = x;
        lastY = y;
        lastMotion = now;
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
