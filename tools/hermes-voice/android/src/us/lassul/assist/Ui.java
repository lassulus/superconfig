package us.lassul.assist;

import android.app.Activity;
import android.graphics.Insets;
import android.util.TypedValue;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;

/** Layout helpers shared by the screens. */
final class Ui {
    private Ui() {}

    static int dp(Activity activity, int value) {
        return (int) (value * activity.getResources().getDisplayMetrics().density);
    }

    /**
     * Pads a screen's root view clear of the status bar, the action bar, the navigation bar and
     * the keyboard: apps targeting Android 15+ are drawn edge to edge, under all of them.
     */
    static void fitBars(Activity activity, View root, final int pad) {
        TypedValue size = new TypedValue();
        activity.getTheme().resolveAttribute(android.R.attr.actionBarSize, size, true);
        final int actionBar = TypedValue.complexToDimensionPixelSize(
                size.data, activity.getResources().getDisplayMetrics());
        if (root instanceof ViewGroup) {
            ((ViewGroup) root).setClipToPadding(false);
        }
        root.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override
            public WindowInsets onApplyWindowInsets(View view, WindowInsets insets) {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars()
                        | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                view.setPadding(bars.left + pad, bars.top + actionBar + pad / 2,
                        bars.right + pad, bars.bottom + pad);
                return WindowInsets.CONSUMED;
            }
        });
    }
}
