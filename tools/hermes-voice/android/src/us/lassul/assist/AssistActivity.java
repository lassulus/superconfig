package us.lassul.assist;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.Intent;
import android.os.Bundle;

/**
 * Entry point (launcher, assist gesture, headset VOICE_COMMAND): unlocks if needed and opens the
 * voice page, which starts listening at once (?listen).
 */
public class AssistActivity extends Activity {
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
        launched = true;
        // Started now, while this activity is in front: from the background Android refuses it.
        startForegroundService(new Intent(this, CallService.class));
        Link.open(this);
    }

    // Back from the page: this activity only sits below it in the task.
    @Override
    protected void onRestart() {
        super.onRestart();
        if (launched) {
            finish();
        }
    }
}
