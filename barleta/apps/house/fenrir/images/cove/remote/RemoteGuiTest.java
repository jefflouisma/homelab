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
    private static boolean menuVisible() throws Exception {
        boolean[] found = {false};
        EventQueue.invokeAndWait(() -> {
            for (Window window : Window.getWindows()) {
                if (window instanceof RemoteMenu && window.isShowing()) found[0] = true;
            }
        });
        return found[0];
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
            robot.mouseMove(500, 550);
            center(false);
            check(activations.get() == 2, "F8 restores normal pointer clicking");
            System.out.println("PASS remote center, hold, release, keyboard, focus restoration and mouse fallback");
        } finally {
            EventQueue.invokeAndWait(() -> {
                for (Window window : Window.getWindows()) window.dispose();
            });
        }
        System.exit(0);
    }
}
