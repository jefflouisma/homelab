package games.fenrir.cove;

import java.awt.*;
import java.awt.event.*;
import java.util.concurrent.atomic.AtomicInteger;
import javax.swing.*;

/** Run under Xvfb with COVE_REMOTE_INPUT=1 and the packaged agent. */
public final class RemoteGuiTest {
    private static JFrame frame;
    private static JTextField field;
    private static JButton button;
    private static final AtomicInteger activations = new AtomicInteger();
    private static final AtomicInteger rightSteps = new AtomicInteger();
    private static final AtomicInteger leftSteps = new AtomicInteger();
    private static Robot robot;

    private static void check(boolean ok, String message) {
        if (!ok) throw new AssertionError(message);
    }

    private static void waitForUi() throws InterruptedException { Thread.sleep(250); }
    private static void key(int code) throws Exception {
        robot.keyPress(code);
        robot.keyRelease(code);
        waitForUi();
    }
    private static void center(boolean hold) throws Exception {
        robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);
        Thread.sleep(hold ? 1000 : 80);
        robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);
        waitForUi();
    }
    private static void controller(String action) throws Exception {
        EventQueue.invokeAndWait(() -> ((CoveRemoteLauncher.RemoteQueue) Toolkit.getDefaultToolkit()
                .getSystemEventQueue()).controller(action));
        waitForUi();
    }
    private static boolean menuVisible() throws Exception {
        boolean[] found = {false};
        EventQueue.invokeAndWait(() -> {
            for (Window window : Window.getWindows()) {
                if (window instanceof RemoteMenu && window.isShowing()) found[0] = true;
            }
        });
        return found[0];
    }

    private static void swipeAcrossEdges(int direction, AtomicInteger steps) throws Exception {
        Rectangle screen = frame.getGraphicsConfiguration().getBounds();
        robot.mouseMove(screen.x + screen.width / 2, screen.y + screen.height * 3 / 4);
        waitForUi();
        int halfway = 0;
        for (int i = 0; i < 120; i++) {
            Point position = MouseInfo.getPointerInfo().getLocation();
            robot.mouseMove(Math.max(screen.x, Math.min(screen.x + screen.width - 1, position.x + direction * 20)), position.y);
            Thread.sleep(12); // Continuous motion can coalesce the exact warp acknowledgement.
            if (i == 59) halfway = steps.get();
        }
        waitForUi();
        check(steps.get() >= halfway + 2, "continuous swipes must keep navigating after repeated screen edges");
    }

    public static void main(String[] arguments) throws Exception {
        try {
            EventQueue.invokeAndWait(() -> {
                frame = new JFrame("Remote integration fixture");
                frame.setDefaultCloseOperation(WindowConstants.DISPOSE_ON_CLOSE);
                JPanel panel = new JPanel(new GridLayout(2, 1));
                field = new JTextField("original");
                button = new JButton("Select this focused button");
                button.addActionListener(event -> activations.incrementAndGet());
                button.addKeyListener(new KeyAdapter() {
                    @Override public void keyPressed(KeyEvent event) {
                        if (event.getKeyCode() == KeyEvent.VK_RIGHT) rightSteps.incrementAndGet();
                        if (event.getKeyCode() == KeyEvent.VK_LEFT) leftSteps.incrementAndGet();
                    }
                });
                // Cove's clickable TV controls also activate on Enter, unlike plain Swing buttons.
                button.getInputMap().put(KeyStroke.getKeyStroke("released ENTER"), "activate");
                button.getActionMap().put("activate", new AbstractAction() {
                    @Override public void actionPerformed(ActionEvent event) { button.doClick(); }
                });
                panel.add(field);
                panel.add(button);
                frame.setContentPane(panel);
                frame.setBounds(100, 100, 1000, 600);
                frame.setVisible(true);
                button.requestFocusInWindow();
            });
            robot = new Robot();
            robot.setAutoDelay(30);
            robot.mouseMove(500, 250); // Over the text field, away from the focused button.
            waitForUi();
            EventQueue.invokeAndWait(() -> button.requestFocusInWindow());
            waitForUi();
            center(false);
            check(activations.get() == 1, "center must select focused control, not pointer location");
            center(true);
            check(menuVisible(), "holding center opens controls");
            check(activations.get() == 1, "holding center cannot also activate the focused item");
            key(KeyEvent.VK_ESCAPE);
            check(!menuVisible(), "menu can be cancelled");

            controller("SELECT_DOWN");
            controller("SELECT_UP");
            check(activations.get() == 2, "Android TV OK selects the focused control");
            controller("SELECT_DOWN");
            controller("CANCEL");
            controller("SELECT_UP");
            check(activations.get() == 2, "disconnect cancellation cannot select on release");
            controller("SELECT_DOWN");
            Thread.sleep(1000);
            controller("SELECT_UP");
            check(menuVisible() && activations.get() == 2, "held Android TV OK opens controls without selecting on release");
            controller("BACK");
            check(!menuVisible(), "controller Back cancels the remote menu first");
            EventQueue.invokeAndWait(() -> button.requestFocusInWindow());
            int oldRight = rightSteps.get(), oldLeft = leftSteps.get();
            controller("RIGHT");
            controller("LEFT");
            check(rightSteps.get() == oldRight + 1 && leftSteps.get() == oldLeft + 1, "controller D-pad produces TV direction keys");

            AtomicInteger backs = new AtomicInteger();
            Runnable[] removeBack = {null};
            EventQueue.invokeAndWait(() -> removeBack[0] = CoveRemoteLauncher.registerBackHandler(backs::incrementAndGet));
            center(true);
            center(false); // Back must call navigation even if Compose has lost child focus.
            waitForUi();
            check(backs.get() == 1, "remote Back invokes the active navigation callback exactly once");
            check(!menuVisible(), "Back closes the remote menu");
            controller("BACK");
            check(backs.get() == 2, "controller Back invokes Cove navigation directly");
            EventQueue.invokeAndWait(() -> removeBack[0].run());

            EventQueue.invokeAndWait(() -> {
                frame.setBounds(frame.getGraphicsConfiguration().getBounds());
                button.requestFocusInWindow();
            });
            waitForUi();
            robot.setAutoDelay(0);
            swipeAcrossEdges(1, rightSteps);
            swipeAcrossEdges(-1, leftSteps);
            robot.setAutoDelay(30);

            EventQueue.invokeAndWait(() -> field.requestFocusInWindow());
            waitForUi();
            center(true);
            key(KeyEvent.VK_DOWN);
            center(false); // Open the on-screen keyboard.
            center(false); // q
            key(KeyEvent.VK_RIGHT);
            center(false); // w
            for (int i = 0; i < 4; i++) key(KeyEvent.VK_DOWN);
            key(KeyEvent.VK_RIGHT);
            key(KeyEvent.VK_RIGHT);
            center(false); // Done
            waitForUi();
            String[] actual = {null};
            EventQueue.invokeAndWait(() -> actual[0] = field.getText());
            check("qw".equals(actual[0]), "remote keyboard must replace focused text; actual=" + actual[0]);
            check(!menuVisible(), "Done restores the application");
            key(KeyEvent.VK_F8);
            Point buttonPoint = button.getLocationOnScreen();
            robot.mouseMove(buttonPoint.x + button.getWidth() / 2, buttonPoint.y + button.getHeight() / 2);
            center(false);
            check(activations.get() == 3, "F8 restores normal pointer clicking");
            System.out.println("PASS remote center, hold, Back, continuous edge swipes, keyboard, focus restoration and mouse fallback");
        } finally {
            EventQueue.invokeAndWait(() -> {
                for (Window window : Window.getWindows()) window.dispose();
            });
        }
        System.exit(0);
    }
}
