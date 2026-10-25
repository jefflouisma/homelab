package games.fenrir.cove;

import java.awt.*;
import java.awt.event.*;
import java.awt.image.BufferedImage;
import java.lang.reflect.InvocationTargetException;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.IdentityHashMap;
import java.util.Map;
import javax.swing.*;

/** Maps the stock Moonlight tvOS pointer protocol into Cove's existing TV key controls. */
public final class CoveRemoteLauncher {
    private static final java.util.Deque<Runnable> backHandlers = new java.util.ArrayDeque<>();

    public static Runnable registerBackHandler(Runnable handler) {
        backHandlers.addLast(handler);
        return () -> backHandlers.removeLastOccurrence(handler);
    }

    public static boolean handleBack() {
        Runnable handler = backHandlers.peekLast();
        if (handler == null) return false;
        handler.run();
        return true;
    }

    public static void main(String[] arguments) throws Throwable {
        install();
        try {
            Class.forName("com.coveninja.cove.desktop.MainKt").getMethod("main", String[].class)
                    .invoke(null, (Object) arguments);
        } catch (InvocationTargetException error) {
            throw error.getCause();
        }
    }

    // The GUI regression fixture uses a full JDK; Cove's jlink runtime needs only main().
    public static void premain(String arguments) { install(); }

    private static void install() {
        if (!"1".equals(System.getenv("COVE_REMOTE_INPUT"))) return;
        EventQueue.invokeLater(() -> {
            try {
                RemoteQueue queue = new RemoteQueue();
                Toolkit.getDefaultToolkit().getSystemEventQueue().push(queue);
                queue.startControllerBridge();
                System.out.println("Cove remote: enabled (center selects; hold center for Back and keyboard; F8 toggles mouse)");
            } catch (Exception error) {
                System.err.println("Cove remote: could not initialize: " + error);
            }
        });
    }

    static final class RemoteQueue extends EventQueue {
        private final RemoteInput input = new RemoteInput();
        private final RemoteInput controllerInput = new RemoteInput();
        private final Map<Window, Cursor> cursors = new IdentityHashMap<>();
        private final Cursor hidden = Toolkit.getDefaultToolkit().createCustomCursor(
                new BufferedImage(16, 16, BufferedImage.TYPE_INT_ARGB), new Point(), "Cove remote");
        private final Robot robot = new Robot();
        private final Timer holdTimer;
        private final Timer controllerHoldTimer;
        private volatile Process controllerBridge;
        private volatile boolean stopping;
        private boolean enabled = true;
        private long nextRecenterWarning;
        private Window pressedWindow;
        private RemoteMenu menu;

        RemoteQueue() throws AWTException {
            holdTimer = new Timer((int) RemoteInput.HOLD_MS, event -> {
                if (input.hold() && pressedWindow != null && pressedWindow.isFocused()) showMenu(pressedWindow);
            });
            holdTimer.setRepeats(false);
            controllerHoldTimer = new Timer((int) RemoteInput.HOLD_MS, event -> {
                Window owner = KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusedWindow();
                if (owner != null && owner.isFocused() && controllerInput.hold()) showMenu(owner);
            });
            controllerHoldTimer.setRepeats(false);
            for (Window window : Window.getWindows()) setCursor(window);
        }

        private void cancelController() {
            controllerHoldTimer.stop();
            controllerInput.cancel();
        }

        // Called on the EDT; controller events never become host-wide X11 input.
        void controller(String action) {
            if ("CANCEL".equals(action)) { cancelController(); return; }
            Window window = KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusedWindow();
            if (!enabled || window == null || !window.isFocused()) { cancelController(); return; }
            switch (action) {
                case "UP" -> tap(KeyEvent.VK_UP);
                case "DOWN" -> tap(KeyEvent.VK_DOWN);
                case "LEFT" -> tap(KeyEvent.VK_LEFT);
                case "RIGHT" -> tap(KeyEvent.VK_RIGHT);
                case "SELECT_DOWN" -> { if (controllerInput.press()) controllerHoldTimer.restart(); }
                case "SELECT_RELEASE" -> controllerHoldTimer.stop();
                case "SELECT_UP" -> {
                    controllerHoldTimer.stop();
                    if (controllerInput.release()) tap(KeyEvent.VK_ENTER);
                }
                case "BACK" -> {
                    cancelController();
                    if (window instanceof RemoteMenu || !handleBack()) tap(KeyEvent.VK_ESCAPE);
                }
                default -> { }
            }
        }

        private void startControllerBridge() {
            Path helper = Path.of("/usr/local/lib/fenrir/gamepad-bridge.py");
            if (!Files.isRegularFile(helper)) return;
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                stopping = true;
                Process child = controllerBridge;
                if (child != null) child.destroy();
            }, "cove-gamepad-stop"));
            Thread reader = new Thread(() -> {
                while (!stopping) {
                    try {
                        Process child = new ProcessBuilder("python3", "-u", helper.toString())
                                .redirectError(ProcessBuilder.Redirect.INHERIT).start();
                        controllerBridge = child;
                        child.getOutputStream().close();
                        try (BufferedReader lines = new BufferedReader(new InputStreamReader(child.getInputStream(), StandardCharsets.UTF_8))) {
                            String line;
                            while ((line = lines.readLine()) != null) {
                                String action = line;
                                EventQueue.invokeLater(() -> controller(action));
                            }
                        }
                        child.waitFor();
                    } catch (Exception error) {
                        if (!stopping) System.err.println("Cove gamepad: bridge stopped: " + error);
                    } finally {
                        Process child = controllerBridge;
                        if (child != null && child.isAlive()) child.destroy();
                        EventQueue.invokeLater(this::cancelController);
                    }
                    if (!stopping) {
                        System.err.println("Cove gamepad: restarting input bridge");
                        try { Thread.sleep(1000); } catch (InterruptedException error) { return; }
                    }
                }
            }, "cove-gamepad-input");
            reader.setDaemon(true);
            reader.start();
        }

        private void setCursor(Window window) {
            if (enabled) {
                cursors.putIfAbsent(window, window.getCursor());
                window.setCursor(hidden);
            } else if (cursors.containsKey(window)) {
                window.setCursor(cursors.remove(window));
            }
        }

        private void showMenu(Window owner) {
            if (menu != null && menu.isDisplayable()) return;
            Component target = KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusOwner();
            menu = new RemoteMenu(owner, target, () -> menu = null);
            menu.setVisible(true);
        }

        @Override protected void dispatchEvent(AWTEvent event) {
            try {
                if (event instanceof WindowEvent windowEvent) {
                    if (windowEvent.getID() == WindowEvent.WINDOW_OPENED) setCursor(windowEvent.getWindow());
                    if (windowEvent.getID() == WindowEvent.WINDOW_CLOSED) cursors.remove(windowEvent.getWindow());
                    if (windowEvent.getID() == WindowEvent.WINDOW_LOST_FOCUS) {
                        holdTimer.stop();
                        input.cancel();
                        cancelController();
                    }
                }
                if (event instanceof KeyEvent key && key.getKeyCode() == KeyEvent.VK_F8) {
                    if (key.getID() == KeyEvent.KEY_RELEASED) {
                        enabled = !enabled;
                        holdTimer.stop();
                        input.cancel();
                        cancelController();
                        for (Window window : Window.getWindows()) setCursor(window);
                        System.out.println("Cove remote: " + (enabled ? "remote navigation" : "normal mouse"));
                    }
                    return;
                }
                if (enabled && event instanceof MouseEvent mouse && handleMouse(mouse)) return;
            } catch (RuntimeException error) {
                // Preserve the application's normal input if the adapter encounters an error.
                enabled = false;
                holdTimer.stop();
                input.cancel();
                cancelController();
                for (Window window : Window.getWindows()) setCursor(window);
                System.err.println("Cove remote: disabled after input error: " + error);
            }
            super.dispatchEvent(event);
        }

        private boolean handleMouse(MouseEvent mouse) {
            Window window = mouse.getComponent() instanceof Window w ? w : SwingUtilities.getWindowAncestor(mouse.getComponent());
            if (window == null || !window.isFocused()) return true;
            if (mouse instanceof MouseWheelEvent wheel) {
                int key = wheel.getPreciseWheelRotation() > 0 ? KeyEvent.VK_DOWN : KeyEvent.VK_UP;
                if (wheel.getPreciseWheelRotation() != 0) tap(key);
                return true;
            }
            switch (mouse.getID()) {
                case MouseEvent.MOUSE_PRESSED -> {
                    if (mouse.getButton() == MouseEvent.BUTTON1 && input.press()) {
                        pressedWindow = window;
                        holdTimer.restart();
                    }
                }
                case MouseEvent.MOUSE_RELEASED -> {
                    if (mouse.getButton() == MouseEvent.BUTTON1) {
                        holdTimer.stop();
                        if (input.release()) tap(KeyEvent.VK_ENTER);
                        pressedWindow = null;
                    } else if (mouse.getButton() == MouseEvent.BUTTON3) {
                        tap(KeyEvent.VK_ESCAPE);
                    }
                }
                case MouseEvent.MOUSE_MOVED, MouseEvent.MOUSE_DRAGGED -> {
                    Point point = mouse.getLocationOnScreen();
                    long now = System.nanoTime() / 1_000_000;
                    Rectangle bounds = window.getGraphicsConfiguration().getBounds();
                    int timeouts = input.recenterTimeouts();
                    int key = input.move(point.x, point.y, now, Math.max(18, bounds.height / 30));
                    if (input.recenterTimeouts() != timeouts && now >= nextRecenterWarning) {
                        nextRecenterWarning = now + 30_000;
                        System.out.println("Cove remote: pointer recenter acknowledgement missed; resumed swipe input");
                    }
                    if (key != 0) tap(key);
                    // Relative swipes must keep working after the pointer reaches an edge.
                    int margin = 32;
                    if (!input.isRecentering() && (point.x < bounds.x + margin || point.x > bounds.x + bounds.width - margin
                            || point.y < bounds.y + margin || point.y > bounds.y + bounds.height - margin)) {
                        int centerX = bounds.x + bounds.width / 2, centerY = bounds.y + bounds.height / 2;
                        input.recenter(point.x, point.y, centerX, centerY, now);
                        robot.mouseMove(centerX, centerY);
                    }
                }
                case MouseEvent.MOUSE_ENTERED -> input.anchor(mouse.getXOnScreen(), mouse.getYOnScreen());
                default -> { }
            }
            // Do not let pointer hover/click change Compose focus after sending a TV action.
            return true;
        }

        private void tap(int key) {
            Component target = KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusOwner();
            if (target != null) postKey(target, key, 0);
        }
    }

    static void postKey(Component target, int key, int modifiers) {
        EventQueue queue = Toolkit.getDefaultToolkit().getSystemEventQueue();
        long now = System.currentTimeMillis();
        queue.postEvent(new KeyEvent(target, KeyEvent.KEY_PRESSED, now, modifiers, key, KeyEvent.CHAR_UNDEFINED));
        queue.postEvent(new KeyEvent(target, KeyEvent.KEY_RELEASED, now + 1, modifiers, key, KeyEvent.CHAR_UNDEFINED));
    }

    static void postText(Component target, String value) {
        postKey(target, KeyEvent.VK_A, InputEvent.CTRL_DOWN_MASK);
        postKey(target, KeyEvent.VK_BACK_SPACE, 0);
        EventQueue queue = Toolkit.getDefaultToolkit().getSystemEventQueue();
        for (char character : value.toCharArray()) {
            queue.postEvent(new KeyEvent(target, KeyEvent.KEY_TYPED, System.currentTimeMillis(), 0,
                    KeyEvent.VK_UNDEFINED, character));
        }
    }
}
