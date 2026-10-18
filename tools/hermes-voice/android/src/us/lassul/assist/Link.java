package us.lassul.assist;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import androidx.browser.customtabs.CustomTabsCallback;
import androidx.browser.customtabs.CustomTabsClient;
import androidx.browser.customtabs.CustomTabsIntent;
import androidx.browser.customtabs.CustomTabsService;
import androidx.browser.customtabs.CustomTabsServiceConnection;
import androidx.browser.customtabs.CustomTabsSession;
import androidx.browser.trusted.TrustedWebActivityIntentBuilder;

/**
 * The voice page, opened as a Trusted Web Activity, else as a Custom Tab, and its postMessage
 * channel: the page reports "started" and "ended" for each call, the app sends "hangup". One per
 * process, used on the main thread only (androidx delivers the callbacks there).
 */
final class Link {
    static final String TAG = "Assist";
    // The app speaks as this origin; assetlinks.json grants it (use_as_origin).
    private static final Uri ORIGIN = Uri.parse("https://assist.lassul.us");
    private static final Uri URL = Uri.parse("https://assist.lassul.us/?listen");

    private static Context app;
    private static CustomTabsServiceConnection connection;
    private static CustomTabsSession session;
    private static boolean twa;
    // Opened before the browser's service connected: launched once it is.
    private static Activity pending;

    private static final CustomTabsCallback CALLBACK = new CustomTabsCallback() {
        @Override
        public void onRelationshipValidationResult(
                int relation, Uri origin, boolean result, Bundle extras) {
            Log.i(TAG, "use_as_origin " + origin + ": " + result);
        }

        // Every page load needs its own channel; the page takes the port from the first message.
        @Override
        public void onNavigationEvent(int event, Bundle extras) {
            if (event == NAVIGATION_FINISHED && session != null) {
                boolean requested = session.requestPostMessageChannel(ORIGIN, ORIGIN, new Bundle());
                Log.i(TAG, "postMessage channel requested: " + requested);
            }
        }

        @Override
        public void onMessageChannelReady(Bundle extras) {
            Log.i(TAG, "postMessage channel ready: " + session.postMessage("hello", null));
        }

        @Override
        public void onPostMessage(String message, Bundle extras) {
            Log.i(TAG, "page: " + message);
            if ("started".equals(message)) {
                CallService.pageStarted();
            } else if ("ended".equals(message)) {
                CallService.pageEnded();
            }
        }
    };

    private Link() {}

    static void open(Activity activity) {
        if (session != null) {
            launch(activity);
            return;
        }
        pending = activity;
        if (connection != null) {
            return;
        }
        String provider = twaProvider(activity);
        twa = provider != null;
        if (provider == null) {
            provider = CustomTabsClient.getPackageName(activity, null);
        }
        app = activity.getApplicationContext();
        connection = new CustomTabsServiceConnection() {
            @Override
            public void onCustomTabsServiceConnected(ComponentName name, CustomTabsClient client) {
                client.warmup(0);
                session = client.newSession(CALLBACK);
                if (session != null) {
                    session.validateRelationship(
                            CustomTabsService.RELATION_USE_AS_ORIGIN, ORIGIN, null);
                }
                Activity waiting = pending;
                pending = null;
                if (waiting != null && !waiting.isFinishing()) {
                    launch(waiting);
                }
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {
                session = null;
            }
        };
        if (provider == null || !CustomTabsClient.bindCustomTabsService(app, provider, connection)) {
            connection = null;
            pending = null;
            launch(activity);
        }
    }

    /** Sends "hangup" to the page, if it is connected. */
    static void hangUp() {
        if (session != null) {
            Log.i(TAG, "hangup sent: " + session.postMessage("hangup", null));
        }
    }

    static void close() {
        if (connection != null) {
            app.unbindService(connection);
        }
        connection = null;
        session = null;
        pending = null;
    }

    /** In the session's browser; without one (no Custom Tabs browser) a plain Custom Tab. */
    private static void launch(Activity activity) {
        Intent intent;
        if (session == null) {
            intent = new CustomTabsIntent.Builder().build().intent.setData(URL);
        } else if (twa) {
            intent = new TrustedWebActivityIntentBuilder(URL).build(session).getIntent();
        } else {
            intent = new CustomTabsIntent.Builder(session).build().intent.setData(URL);
        }
        activity.startActivity(intent);
    }

    /** The first browser offering Trusted Web Activities, null if none does. */
    private static String twaProvider(Context context) {
        Intent intent = new Intent(CustomTabsService.ACTION_CUSTOM_TABS_CONNECTION);
        for (ResolveInfo info :
                context.getPackageManager()
                        .queryIntentServices(intent, PackageManager.GET_RESOLVED_FILTER)) {
            if (info.filter != null
                    && info.filter.hasCategory(CustomTabsService.TRUSTED_WEB_ACTIVITY_CATEGORY)) {
                return info.serviceInfo.packageName;
            }
        }
        return null;
    }
}
