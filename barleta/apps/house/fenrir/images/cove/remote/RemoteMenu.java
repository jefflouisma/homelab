package games.fenrir.cove;

import java.awt.*;
import java.awt.event.*;
import javax.swing.*;

/** Remote-only Back and text entry, since stock Moonlight reserves the other Siri buttons. */
final class RemoteMenu extends JDialog {
    private static final long serialVersionUID = 1L;
    private static final String[][] LETTERS = {
        {"q", "w", "e", "r", "t", "y", "u", "i", "o", "p"},
        {"a", "s", "d", "f", "g", "h", "j", "k", "l", "'"},
        {"z", "x", "c", "v", "b", "n", "m", ",", ".", "?"},
        {"1", "2", "3", "4", "5", "6", "7", "8", "9", "0"},
        {"Shift", "Space", "Delete", "Done", "Cancel"}
    };
    private final Window owner;
    private final Component target;
    private final transient Runnable closed;
    private final Surface surface = new Surface();
    private final StringBuilder text = new StringBuilder();
    private boolean keyboard, uppercase;
    private int row, column;

    RemoteMenu(Window owner, Component target, Runnable closed) {
        super(owner, "Cove remote controls", ModalityType.MODELESS);
        this.owner = owner;
        this.target = target;
        this.closed = closed;
        setUndecorated(true);
        setDefaultCloseOperation(DISPOSE_ON_CLOSE);
        setContentPane(surface);
        setBounds(owner.getBounds());
        addWindowListener(new WindowAdapter() {
            @Override public void windowOpened(WindowEvent event) { surface.requestFocusInWindow(); }
            @Override public void windowClosed(WindowEvent event) { closed.run(); }
        });
        surface.setFocusable(true);
        surface.addKeyListener(new KeyAdapter() {
            @Override public void keyPressed(KeyEvent event) {
                switch (event.getKeyCode()) {
                    case KeyEvent.VK_UP -> moveSelection(-1, 0);
                    case KeyEvent.VK_DOWN -> moveSelection(1, 0);
                    case KeyEvent.VK_LEFT -> moveSelection(0, -1);
                    case KeyEvent.VK_RIGHT -> moveSelection(0, 1);
                    case KeyEvent.VK_ESCAPE -> { event.consume(); finish(null); }
                    case KeyEvent.VK_BACK_SPACE -> delete();
                    default -> { }
                }
            }
            @Override public void keyReleased(KeyEvent event) {
                if (event.getKeyCode() == KeyEvent.VK_ENTER || event.getKeyCode() == KeyEvent.VK_SPACE) activate();
            }
        });
    }

    private void moveSelection(int dr, int dc) {
        if (keyboard) {
            row = Math.max(0, Math.min(LETTERS.length - 1, row + dr));
            column = Math.max(0, Math.min(LETTERS[row].length - 1, column + dc));
        } else {
            row = Math.max(0, Math.min(2, row + dr));
        }
        surface.repaint();
    }

    private void delete() {
        if (text.length() > 0) text.deleteCharAt(text.length() - 1);
        surface.repaint();
    }

    private void activate() {
        if (!keyboard) {
            if (row == 0) finish(() -> CoveRemoteLauncher.postKey(target, KeyEvent.VK_ESCAPE, 0));
            else if (row == 1) { keyboard = true; row = column = 0; surface.repaint(); }
            else finish(null);
            return;
        }
        String key = LETTERS[row][column];
        switch (key) {
            case "Shift" -> uppercase = !uppercase;
            case "Space" -> text.append(' ');
            case "Delete" -> delete();
            case "Done" -> { finish(() -> CoveRemoteLauncher.postText(target, text.toString())); return; }
            case "Cancel" -> { finish(null); return; }
            default -> { if (text.length() < 512) text.append(uppercase ? key.toUpperCase(java.util.Locale.ROOT) : key); }
        }
        surface.repaint();
    }

    private void finish(Runnable action) {
        setVisible(false);
        owner.toFront();
        owner.requestFocus();
        if (target != null) target.requestFocusInWindow();
        if (action != null && target != null) {
            int[] attempts = {0};
            Timer restore = new Timer(100, event -> {
                Timer timer = (Timer) event.getSource();
                if (!owner.isDisplayable() || !target.isShowing()) {
                    timer.stop();
                    dispose();
                } else if (owner.isFocused() && target.isFocusOwner()) {
                    timer.stop();
                    dispose();
                    action.run();
                } else if (++attempts[0] >= 10) {
                    timer.stop();
                    // Retain typed text for retry rather than send it to an unrelated control.
                    setVisible(true);
                    surface.requestFocusInWindow();
                } else {
                    owner.requestFocus();
                    target.requestFocusInWindow();
                }
            });
            restore.start();
        } else dispose();
    }

    private final class Surface extends JPanel {
        private static final long serialVersionUID = 1L;
        @Override protected void paintComponent(Graphics graphics) {
            super.paintComponent(graphics);
            Graphics2D g = (Graphics2D) graphics.create();
            g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
            g.setColor(new Color(16, 20, 28));
            g.fillRect(0, 0, getWidth(), getHeight());
            double scale = Math.min(getWidth() / 1280.0, getHeight() / 720.0);
            g.translate((getWidth() - 1280 * scale) / 2, (getHeight() - 720 * scale) / 2);
            g.scale(scale, scale);
            g.setFont(new Font(Font.SANS_SERIF, Font.BOLD, 36));
            g.setColor(Color.WHITE);
            g.drawString(keyboard ? "On-screen keyboard" : "Remote controls", 90, 85);
            g.setFont(new Font(Font.SANS_SERIF, Font.PLAIN, 22));
            g.setColor(new Color(190, 199, 213));
            g.drawString(keyboard ? "Done replaces the text in the field you focused. Back cancels." :
                    "Use arrows or swipes to move. Click center to select.", 90, 128);
            if (keyboard) {
                g.setColor(new Color(35, 42, 55));
                g.fillRoundRect(90, 158, 1100, 66, 14, 14);
                g.setColor(Color.WHITE);
                g.setFont(new Font(Font.SANS_SERIF, Font.PLAIN, 26));
                String preview = text.length() > 65 ? "..." + text.substring(text.length() - 65) : text.toString();
                g.drawString(preview.isEmpty() ? "Enter text..." : preview, 110, 201);
                for (int r = 0; r < LETTERS.length; r++) {
                    int width = 1100 / LETTERS[r].length;
                    for (int c = 0; c < LETTERS[r].length; c++) {
                        String label = LETTERS[r][c];
                        if (uppercase && label.length() == 1) label = label.toUpperCase(java.util.Locale.ROOT);
                        button(g, label, 90 + c * width, 252 + r * 72, width - 10, 60, row == r && column == c);
                    }
                }
            } else {
                String[] actions = {"Back to previous screen", "On-screen keyboard", "Close menu"};
                for (int i = 0; i < actions.length; i++) button(g, actions[i], 90, 200 + i * 100, 1100, 80, row == i);
            }
            g.setColor(new Color(190, 199, 213));
            g.setFont(new Font(Font.SANS_SERIF, Font.PLAIN, 20));
            g.drawString(keyboard ? "Select Cancel to close without changing the field." :
                    "Hold center to open these controls from anywhere in Cove.", 90, 675);
            g.dispose();
        }

        private void button(Graphics2D g, String label, int x, int y, int w, int h, boolean selected) {
            g.setColor(selected ? new Color(75, 210, 168) : new Color(37, 46, 60));
            g.fillRoundRect(x, y, w, h, 14, 14);
            g.setColor(selected ? new Color(12, 26, 23) : Color.WHITE);
            g.setFont(new Font(Font.SANS_SERIF, selected ? Font.BOLD : Font.PLAIN, 26));
            FontMetrics metrics = g.getFontMetrics();
            g.drawString(label, x + (w - metrics.stringWidth(label)) / 2, y + (h - metrics.getHeight()) / 2 + metrics.getAscent());
        }
    }
}
