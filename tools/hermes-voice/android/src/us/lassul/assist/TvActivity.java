package us.lassul.assist;

import android.app.Activity;
import android.app.PictureInPictureParams;
import android.app.RemoteAction;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.drawable.Icon;
import android.os.Bundle;
import android.util.Rational;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.webkit.WebChromeClient;
import android.widget.FrameLayout;
import android.widget.Toast;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;
import java.util.Arrays;

/**
 * The TV channel full screen (Tv's page). Leaving it (home, back, another app) shrinks it to
 * picture-in-picture; closing that stops the TV, its Audio only plays on without the picture,
 * like the display going off does. Opened or shared tv.lassul.us links become the TV URL.
 */
public class TvActivity extends Activity {
    private FrameLayout frame;
    private View custom;
    private WebChromeClient.CustomViewCallback customClosed;
    private boolean stopped;
    // The picture-in-picture parameters last set.
    private String pipState;
    private final Runnable redraw = new Runnable() {
        @Override
        public void run() {
            refresh();
        }
    };
    private final OnBackInvokedCallback back = new OnBackInvokedCallback() {
        @Override
        public void onBackInvoked() {
            if (custom != null) {
                WebChromeClient.CustomViewCallback closed = customClosed;
                hideCustom();
                closed.onCustomViewHidden();
            } else if (!enterPictureInPictureMode(pipParams())) {
                // Picture-in-picture turned off for the app: it plays on in the background.
                moveTaskToBack(true);
            }
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        takeLink(getIntent());
        if (Tv.url(this) == null) {
            Toast.makeText(this, "Set the TV URL first", Toast.LENGTH_LONG).show();
            startActivity(new Intent(this, SettingsActivity.class));
            finish();
            return;
        }
        WindowManager.LayoutParams attributes = getWindow().getAttributes();
        attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        getWindow().setAttributes(attributes);
        frame = new FrameLayout(this);
        frame.setBackgroundColor(Color.BLACK);
        setContentView(frame);
        startForegroundService(new Intent(this, TvService.class));
        Tv.show(this, frame);
        Live.watch(redraw);
        getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT, back);
        refresh();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        takeLink(intent);
    }

    @Override
    protected void onStart() {
        super.onStart();
        stopped = false;
    }

    @Override
    protected void onResume() {
        super.onResume();
        WindowInsetsController bars = getWindow().getInsetsController();
        if (bars != null) {
            bars.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            bars.hide(WindowInsets.Type.systemBars());
        }
    }

    // No WebView.onPause(): the channel plays on behind the lock screen and in the background.
    @Override
    protected void onStop() {
        stopped = true;
        super.onStop();
    }

    @Override
    public void onPictureInPictureModeChanged(boolean inPip, Configuration config) {
        super.onPictureInPictureModeChanged(inPip, config);
        // Audio only took the page off this screen already.
        if (!Tv.shows(this)) {
            return;
        }
        if (!inPip && stopped) {
            // Closed instead of expanded.
            Tv.stop(this);
            return;
        }
        Tv.setPip(inPip);
    }

    @Override
    protected void onDestroy() {
        Live.unwatch(redraw);
        if (frame != null) {
            if (custom != null) {
                WebChromeClient.CustomViewCallback closed = customClosed;
                hideCustom();
                closed.onCustomViewHidden();
            }
            // Swiped away or closed in picture-in-picture; not when the system reclaims it.
            if (isFinishing() && Tv.shows(this)) {
                Tv.stop(this);
            } else {
                Tv.hide(this);
            }
        }
        super.onDestroy();
    }

    /** The page's fullscreen element, over the page. */
    void showCustom(View view, WebChromeClient.CustomViewCallback closed) {
        hideCustom();
        custom = view;
        customClosed = closed;
        frame.addView(view, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
    }

    void hideCustom() {
        if (custom != null) {
            frame.removeView(custom);
            custom = null;
            customClosed = null;
        }
    }

    private void refresh() {
        if (Tv.muted()) {
            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        } else {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        }
        String state = pipAspect() + " " + Tv.paused();
        if (!state.equals(pipState)) {
            pipState = state;
            setPictureInPictureParams(pipParams());
        }
    }

    private PictureInPictureParams pipParams() {
        boolean paused = Tv.paused();
        return new PictureInPictureParams.Builder()
                .setAspectRatio(pipAspect())
                .setAutoEnterEnabled(true)
                .setSeamlessResizeEnabled(false)
                .setActions(Arrays.asList(
                        pipAction(paused ? android.R.drawable.ic_media_play
                                        : android.R.drawable.ic_media_pause,
                                paused ? "Play" : "Pause",
                                paused ? TvService.ACTION_PLAY : TvService.ACTION_PAUSE),
                        pipAction(android.R.drawable.ic_lock_silent_mode_off, "Audio only",
                                TvService.ACTION_AUDIO)))
                .build();
    }

    private RemoteAction pipAction(int icon, String label, String action) {
        return new RemoteAction(Icon.createWithResource(this, icon), label, label,
                TvService.control(this, action));
    }

    // The video's, within what picture-in-picture allows.
    private static Rational pipAspect() {
        float ratio = Tv.aspect().floatValue();
        if (ratio > 2.39f) {
            return new Rational(239, 100);
        }
        if (ratio < 1 / 2.39f) {
            return new Rational(100, 239);
        }
        return Tv.aspect();
    }

    private void takeLink(Intent intent) {
        String text = Intent.ACTION_VIEW.equals(intent.getAction())
                ? intent.getDataString()
                : Intent.ACTION_SEND.equals(intent.getAction())
                        ? intent.getStringExtra(Intent.EXTRA_TEXT)
                        : null;
        if (text == null) {
            return;
        }
        String url = Tv.parse(text, true);
        if (url == null) {
            Toast.makeText(this, "No tv.lassul.us link in it", Toast.LENGTH_LONG).show();
        } else if (!url.equals(Tv.url(this))) {
            Tv.saveUrl(this, url);
            Toast.makeText(this, "TV URL saved", Toast.LENGTH_SHORT).show();
        }
    }
}
