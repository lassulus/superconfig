package us.lassul.assist;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Bundle;
import androidx.browser.customtabs.CustomTabsClient;
import androidx.browser.customtabs.CustomTabsIntent;
import androidx.browser.customtabs.CustomTabsService;
import androidx.browser.customtabs.CustomTabsServiceConnection;
import androidx.browser.customtabs.CustomTabsSession;
import androidx.browser.trusted.TrustedWebActivityIntentBuilder;

/**
 * Opens the voice page as a Trusted Web Activity, else as a Custom Tab or in the browser. The
 * page starts listening at once (?listen).
 */
public class AssistActivity extends Activity {
    private static final Uri URL = Uri.parse("https://assist.lassul.us/?listen");

    private CustomTabsServiceConnection connection;
    private boolean launched;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        KeyguardManager keyguard = getSystemService(KeyguardManager.class);
        if (!keyguard.isKeyguardLocked()) {
            open();
            return;
        }
        // Started over the lock screen (showWhenLocked): the browser cannot show there.
        keyguard.requestDismissKeyguard(this, new KeyguardManager.KeyguardDismissCallback() {
            @Override
            public void onDismissSucceeded() {
                open();
            }

            @Override
            public void onDismissCancelled() {
                finish();
            }

            @Override
            public void onDismissError() {
                finish();
            }
        });
    }

    private void open() {
        String provider = twaProvider();
        if (provider == null) {
            openCustomTab();
            return;
        }
        connection = new CustomTabsServiceConnection() {
            @Override
            public void onCustomTabsServiceConnected(ComponentName name, CustomTabsClient client) {
                if (launched) {
                    return;
                }
                client.warmup(0);
                CustomTabsSession session = client.newSession(null);
                if (session == null) {
                    openCustomTab();
                    return;
                }
                launch(new TrustedWebActivityIntentBuilder(URL).build(session).getIntent());
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {}
        };
        if (!CustomTabsClient.bindCustomTabsService(this, provider, connection)) {
            connection = null;
            openCustomTab();
        }
    }

    /** The first browser offering Trusted Web Activities, null if none does. */
    private String twaProvider() {
        Intent intent = new Intent(CustomTabsService.ACTION_CUSTOM_TABS_CONNECTION);
        for (ResolveInfo info :
                getPackageManager().queryIntentServices(intent, PackageManager.GET_RESOLVED_FILTER)) {
            if (info.filter != null
                    && info.filter.hasCategory(CustomTabsService.TRUSTED_WEB_ACTIVITY_CATEGORY)) {
                return info.serviceInfo.packageName;
            }
        }
        return null;
    }

    /** A Custom Tab where supported; other browsers ignore its extras. */
    private void openCustomTab() {
        launch(new CustomTabsIntent.Builder().build().intent.setData(URL));
    }

    private void launch(Intent intent) {
        launched = true;
        startActivity(intent);
    }

    // Back from the page: this activity only sits below it in the task.
    @Override
    protected void onRestart() {
        super.onRestart();
        if (launched) {
            finish();
        }
    }

    @Override
    protected void onDestroy() {
        if (connection != null) {
            unbindService(connection);
        }
        super.onDestroy();
    }
}
