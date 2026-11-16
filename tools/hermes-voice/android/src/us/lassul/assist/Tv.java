package us.lassul.assist;

import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.MutableContextWrapper;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.Rational;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONException;

/**
 * The synced TV channel (tools/tv): its page in one WebView that outlives the TV screen, so
 * the channel plays on without the picture (TvService keeps it in the foreground). Without a
 * screen the page plays only the sound (?audio, tv.setAudioOnly) and does not download the
 * video. Paused means muted: the channel is live and the page stays in sync, so playing again
 * is where the channel is now. Main thread only.
 */
final class Tv {
    private static final String PREFS = "tv";
    private static final String HOST = "tv.lassul.us";
    private static final Pattern LINK = Pattern.compile("https?://\\S+");
    private static final long POLL_MS = 5000;
    // In picture-in-picture the page's chrome goes and the subtitles grow to stay readable.
    private static final String PIP_CSS = "#info, #controls, #panel, #debug { display: none !important; }"
            + " video::cue { font-size: 9vh !important; }";
    // What runs and the size of the video on screen (tools/tv/static/player.js: #now, .standby).
    private static final String INFO = "(() => {"
            + " const video = document.querySelector('video:not(.standby)');"
            + " const now = document.getElementById('now');"
            + " return [now ? now.textContent : '', video ? video.videoWidth : 0,"
            + " video ? video.videoHeight : 0];"
            + " })()";

    private static final Handler main = new Handler(Looper.getMainLooper());
    private static MutableContextWrapper base;
    private static WebView view;
    private static TvActivity screen;
    private static boolean paused;
    private static boolean pip;
    private static String title = "";
    private static Rational aspect = new Rational(16, 9);
    // The mute, picture-in-picture and audio-only state the page has; null after a (re)load.
    private static String applied;

    private static final Runnable apply = new Runnable() {
        @Override
        public void run() {
            apply();
        }
    };
    private static final Runnable poll = new Runnable() {
        @Override
        public void run() {
            if (view == null) {
                return;
            }
            view.evaluateJavascript(INFO, new ValueCallback<String>() {
                @Override
                public void onReceiveValue(String value) {
                    info(value);
                }
            });
            main.postDelayed(this, POLL_MS);
        }
    };

    private Tv() {}

    /** The channel's page, https://tv.lassul.us/<secret>/; null until set. */
    static String url(Context context) {
        return prefs(context).getString("url", null);
    }

    /** Saves the URL (from parse()); a running TV switches to it. */
    static void saveUrl(Context context, String url) {
        prefs(context).edit().putString("url", url).apply();
        if (view != null) {
            view.loadUrl(page(url));
        }
    }

    /** The page to load for the channel at url: without a screen, its audio only. */
    private static String page(String url) {
        return screen != null ? url
                : Uri.parse(url).buildUpon().appendQueryParameter("audio", "1").build().toString();
    }

    /**
     * The first http(s) URL in the text, as a directory (the player loads api/ and media/
     * relative to it); with tvOnly only one on tv.lassul.us. Null without one.
     */
    static String parse(String text, boolean tvOnly) {
        if (text == null) {
            return null;
        }
        Matcher link = LINK.matcher(text);
        while (link.find()) {
            Uri uri = Uri.parse(link.group());
            if (uri.getHost() == null || (tvOnly && !HOST.equals(uri.getHost()))) {
                continue;
            }
            String path = uri.getEncodedPath() == null ? "" : uri.getEncodedPath();
            if (!path.endsWith("/")) {
                uri = uri.buildUpon().encodedPath(path + "/").build();
            }
            return uri.toString();
        }
        return null;
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static boolean on() {
        return view != null;
    }

    static boolean paused() {
        return paused;
    }

    /** Silent: paused, or a call runs (CallService.state()). */
    static boolean muted() {
        return paused || CallService.state() != null;
    }

    static boolean showing() {
        return screen != null;
    }

    static boolean shows(TvActivity activity) {
        return screen == activity;
    }

    /** What runs now, empty while unknown. */
    static String title() {
        return title;
    }

    static Rational aspect() {
        return aspect;
    }

    static void setPaused(boolean next) {
        paused = next;
        Live.changed();
    }

    static void setPip(boolean next) {
        pip = next;
        Live.changed();
    }

    /** Loads the channel unless it runs already; false without a TV URL. */
    static boolean start(Context context) {
        if (view != null) {
            return true;
        }
        String url = url(context);
        if (url == null) {
            return false;
        }
        // The screen lends its activity while it shows the page (fullscreen, dialogs).
        base = new MutableContextWrapper(context.getApplicationContext());
        view = new Page(base);
        WebSettings settings = view.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setMediaPlaybackRequiresUserGesture(false);
        view.setBackgroundColor(Color.BLACK);
        // The page plays on without a screen, so its renderer must not be dropped.
        view.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false);
        view.setWebViewClient(new Client());
        view.setWebChromeClient(new Chrome());
        applied = null;
        view.loadUrl(page(url));
        Live.watch(apply);
        main.postDelayed(poll, POLL_MS);
        Live.changed();
        return true;
    }

    /** Puts the page on the screen; false without a TV URL. */
    static boolean show(TvActivity activity, ViewGroup frame) {
        if (url(activity) == null) {
            return false;
        }
        // Before start(), so a new page loads with the video.
        screen = activity;
        start(activity);
        base.setBaseContext(activity);
        detach();
        frame.addView(view, 0, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        Live.changed();
        return true;
    }

    /** Takes the page off the screen; it plays on. */
    static void hide(TvActivity activity) {
        if (screen != activity) {
            return;
        }
        screen = null;
        pip = false;
        if (view != null) {
            // Detached, a page that has been on a screen counts as hidden and its video pauses
            // (Page); a new one that never was plays on. It loads in a few seconds, in sync,
            // and only the sound.
            Context context = base.getApplicationContext();
            close();
            start(context);
        }
        Live.changed();
    }

    /** Ends the TV: the screen closes and the page goes. */
    static void stop(Context context) {
        TvActivity shown = screen;
        screen = null;
        pip = false;
        if (shown != null) {
            shown.finishAndRemoveTask();
        }
        close();
        paused = false;
        context.stopService(new Intent(context, TvService.class));
        Live.changed();
    }

    /** Closes the screen; the channel plays on (TvService). */
    static void audioOnly() {
        TvActivity shown = screen;
        if (shown != null) {
            hide(shown);
            shown.finishAndRemoveTask();
        }
    }

    private static void close() {
        if (view == null) {
            return;
        }
        Live.unwatch(apply);
        main.removeCallbacks(poll);
        detach();
        view.destroy();
        view = null;
        base = null;
        title = "";
        aspect = new Rational(16, 9);
    }

    private static void detach() {
        ViewGroup parent = (ViewGroup) view.getParent();
        if (parent != null) {
            parent.removeView(view);
        }
    }

    /**
     * Tells the page whether to be silent, whether it is in picture-in-picture and whether it
     * plays only the sound (no screen; a page shown again loads the video at where it is).
     */
    private static void apply() {
        if (view == null) {
            return;
        }
        boolean muted = muted();
        boolean audio = screen == null;
        String state = muted + " " + pip + " " + audio;
        if (state.equals(applied)) {
            return;
        }
        applied = state;
        view.evaluateJavascript("(() => {"
                + " for (const video of document.querySelectorAll('video')) video.muted = " + muted + ";"
                + " let style = document.getElementById('assist-pip');"
                + " if (!style) {"
                + " style = document.createElement('style');"
                + " style.id = 'assist-pip';"
                + " style.textContent = '" + PIP_CSS + "';"
                + " document.head.append(style);"
                + " }"
                + " style.disabled = " + !pip + ";"
                + " window.tv?.setAudioOnly(" + audio + ");"
                + " })()", null);
    }

    private static void info(String value) {
        if (view == null) {
            return;
        }
        try {
            JSONArray info = new JSONArray(value);
            String now = info.optString(0).trim();
            int width = info.optInt(1);
            int height = info.optInt(2);
            Rational size = width > 0 && height > 0 ? new Rational(width, height) : aspect;
            if (!now.equals(title)
                    || Math.abs(size.floatValue() - aspect.floatValue()) > 0.01f) {
                title = now;
                aspect = size;
                Live.changed();
            }
        } catch (JSONException error) {
            // "null" while the page loads.
        }
    }

    private static final class Client extends WebViewClient {
        @Override
        public void onPageStarted(WebView page, String url, Bitmap favicon) {
            applied = null;
        }

        @Override
        public void onPageFinished(WebView page, String url) {
            applied = null;
            apply();
            // Its "Tap to start": playing needs no gesture here.
            page.evaluateJavascript("document.getElementById('start')?.click()", null);
        }

        // Links on the page (what runs now) open in the browser; the TV stays.
        @Override
        public boolean shouldOverrideUrlLoading(WebView page, WebResourceRequest request) {
            Uri link = request.getUrl();
            String own = url(page.getContext());
            if (own != null && Uri.parse(own).getHost().equals(link.getHost())) {
                return false;
            }
            try {
                page.getContext().startActivity(new Intent(Intent.ACTION_VIEW, link)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            } catch (ActivityNotFoundException error) {
                Log.w(CallService.TAG, "no app for " + link);
            }
            return true;
        }

        // A crashed or reclaimed renderer takes the page along: start it again.
        @Override
        public boolean onRenderProcessGone(WebView page, RenderProcessGoneDetail detail) {
            if (page != view) {
                return true;
            }
            Log.w(CallService.TAG, "TV renderer gone, crashed: " + detail.didCrash());
            Context context = base.getApplicationContext();
            TvActivity shown = screen;
            ViewGroup frame = (ViewGroup) view.getParent();
            close();
            if (shown != null && frame != null) {
                show(shown, frame);
            } else {
                start(context);
            }
            return true;
        }
    }

    private static final class Chrome extends WebChromeClient {
        // The page's fullscreen button: the TV screen is full screen already, and WebView's own
        // fullscreen view would stop the video once it is hidden (Page), so the page stays.
        @Override
        public void onShowCustomView(View custom, CustomViewCallback closed) {
            closed.onCustomViewHidden();
        }

        // Instead of a grey play button until the video starts.
        @Override
        public Bitmap getDefaultVideoPoster() {
            return Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888);
        }
    }

    /**
     * The page, playing with the screen off and behind other apps. Chromium pauses a video with
     * sound once its page is hidden (WebMediaPlayerImpl::ShouldPausePlaybackWhenHidden), and a
     * WebView's page is hidden while it is detached after having been attached, or while its
     * window is not visible (BrowserViewRenderer::IsClientVisible). Its window counts as visible
     * here; detaching is up to hide().
     */
    private static final class Page extends WebView {
        Page(Context context) {
            super(context);
        }

        @Override
        protected void onWindowVisibilityChanged(int visibility) {
            super.onWindowVisibilityChanged(View.VISIBLE);
        }
    }
}
